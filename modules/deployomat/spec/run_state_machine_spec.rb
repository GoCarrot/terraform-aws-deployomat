# frozen_string_literal: true

require 'json'
require 'rspec'
require_relative 'support/state_machine_graph'

# Structure checks on cancel.json and undeploy.json. A run ends one of two ways: the Lambda step that decided it
# marks its result Reported, or Start answered something nothing matched and a Report task puts the failed event.
# No state on the way to an ending names a path an error result can lack: a missing path is States.Runtime,
# which a States.ALL Catch doesn't catch.
RSpec.describe 'state_machines/cancel.json and undeploy.json' do # rubocop:disable RSpec/DescribeClass
  include StateMachineGraph

  %w[cancel undeploy].each do |name|
    context "with #{name}.json" do
      let(:machine) { name }
      let(:lambda_steps) { states.select { |_, s| s['Type'] == 'Task' && s['Resource'].to_s.start_with?('${') } }

      it 'reaches Fail only through Report, and FailReported only through ReportBranch' do
        into = ->(target) { states.select { |_, s| targets(s).include?(target) }.keys }

        expect(into.call('Fail')).to match_array(%w[Report ReportBranch])
        expect(into.call('FailReported')).to eq(['ReportBranch'])
        expect(into.call('Report')).to eq(['StartBranch'])
        expect(states['StartBranch']['Default']).to eq('Report')
      end

      it 'hands Report the whole state, nothing it would have to find first' do
        expect(states['Report']['Parameters']).to eq(
          'AllInput.$' => '$', 'ExecutionArn.$' => '$$.Execution.Id', 'Step' => 'Report'
        )
        expect(states['Report']['ResultPath']).to eq('$.Outcome')
        expect(states['Report']['Catch']).to eq([{ 'ErrorEquals' => ['States.ALL'], 'ResultPath' => '$.ReportError',
                                                   'Next' => 'Fail' }])
      end

      it 'checks Reported is present before comparing it, in rules of their own' do
        expect(states['ReportBranch']['Choices']).to eq(
          [{ 'Not' => { 'Variable' => '$.Outcome.Reported', 'IsPresent' => true }, 'Next' => 'Fail' },
           { 'Variable' => '$.Outcome.Reported', 'BooleanEquals' => true, 'Next' => 'FailReported' }]
        )
        expect(states['ReportBranch']['Default']).to eq('Fail')
      end

      it 'reads only a guarded Reported after Report' do
        after = reachable('ReportBranch')

        expect(after.flat_map { |n| paths(states[n]) }.uniq).to eq(['$.Outcome.Reported'])
      end

      it 'ends with the error status readers skip, and a plain Fail for a run nothing reported' do
        expect(states['FailReported']).to include('Type' => 'Fail', 'Error' => 'Deployomat.Reported')
        expect(states['Fail']).to eq('Type' => 'Fail')
      end

      it 'hands every Lambda step the run\'s ExecutionArn and whole input' do
        steps = lambda_steps.reject { |n, _| n == 'Report' }

        expect(steps).not_to be_empty
        steps.each do |step_name, state|
          expect(state['Parameters']).to include('ExecutionArn.$' => '$$.Execution.Id', 'AllInput.$' => '$'), step_name
        end
      end
    end
  end

  context 'with the endings undeploy.json lets Start decide' do
    let(:machine) { 'undeploy' }

    it 'copies Reported from the Lambda result into every one' do
      passes = states.select { |_, s| s['Type'] == 'Pass' && s['End'] }

      expect(passes.keys).to match_array(%w[KnownError Success FailConcurrentDeploy])
      passes.each do |name, state|
        expect(state['Parameters']['Reported.$']).to eq('$.StartResult.Reported'), name
      end
    end
  end

  context 'with the endings cancel.json has' do
    let(:machine) { 'cancel' }

    it 'ends in FinishCancel, whose result carries Reported, or in Fail' do
      ends = states.select { |_, s| s['End'] || %w[Fail Succeed].include?(s['Type']) }.keys

      expect(ends).to match_array(%w[FinishCancel Fail FailReported])
    end
  end
end
