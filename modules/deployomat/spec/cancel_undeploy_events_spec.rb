# frozen_string_literal: true

require_relative 'spec_helper'

# Undeploy and top-level cancel runs put their own events, the way deploys do: `started` once the work
# begins, then the finished event from the step that ends the run, and the result says whether it landed.
# A cancel another execution started puts nothing: its parent reports.
RSpec.describe LambdaFunctions::Handler, '.cancel and .undeploy events' do
  include_context 'with deploy world'

  let(:parent_arn) { DEPLOY_EXECUTION_ARN }

  def undeploy_step(step: 'Start', input: {}, arn: UNDEPLOY_EXECUTION_ARN)
    event = base_event.merge('DeployId' => 'exec-u', 'Step' => step, 'ExecutionArn' => arn, 'AllInput' => input)
    LambdaFunctions::Handler.undeploy(event: event, context: nil)
  end

  def cancel_step(name, input: base_event, arn: CANCEL_EXECUTION_ARN)
    event = base_event.merge('DeployId' => 'exec-c', 'Step' => name, 'ExecutionArn' => arn, 'AllInput' => input)
    LambdaFunctions::Handler.cancel(event: event, context: nil)
  end

  def phases
    world.deploy_events.map { |e| e.values_at('kind', 'phase') }
  end

  describe 'undeploy' do
    before { world.with_template.with_production }

    it 'puts started, then completed as the last thing it does' do
      expect(undeploy_step).to eq(Status: :complete, Reported: true)

      expect(phases).to eq([%w[undeploy started], %w[undeploy completed]])
      expect(world.deploy_events.last).to include(
        'event_id' => 'exec-u/completed', 'step' => 'Start', 'status' => 'complete', 'service' => service,
        'account' => slug, 'ami' => nil, 'ami_tags' => {}, 'execution_arn' => UNDEPLOY_EXECUTION_ARN, 'errors' => []
      )
      expect(world.calls(:put_events).length).to eq(2)
      # Completed is last: the row is already gone when it goes out.
      expect(world.requests.last.first).to eq(:put_events)
    end

    it 'puts only a failed event for a service that is not deployed' do
      world.item.delete('production_asg_name')

      expect(undeploy_step).to include(Status: :fail, Reported: true)
      expect(phases).to eq([%w[undeploy failed]])
      expect(world.deploy_events.first['errors'].first).to match(/No production ASG of thezoo/)
    end

    it 'puts no finished event when a step raises, leaving the run to the backstop' do
      world.fail_with(:delete_auto_scaling_group, 'ValidationError')

      expect { undeploy_step }.to raise_error(Aws::AutoScaling::Errors::ValidationError)
      # The run ends FAILED with the Lambda's error, which the status-event backstop reports.
      expect(phases).to eq([%w[undeploy started]])
    end

    it 'puts one failed event for a concurrent deploy it is configured to fail on' do
      world.item['deploy_asg_name'] = 'thezoo-racing'

      result = undeploy_step(input: { 'UndeployConfig' => { 'OnConcurrentDeploy' => 'fail' } })

      expect(result).to eq(Status: :deploy_active, OnConcurrentDeploy: 'fail', Reported: true)
      expect(world.deploy_events).to contain_exactly(
        include('phase' => 'failed', 'status' => 'deploy_active', 'errors' => [Deployomat::Undeploy::CONCURRENT])
      )
    end

    it 'puts nothing for a concurrent deploy it will cancel, then one started when it comes back' do
      world.item['deploy_asg_name'] = 'thezoo-racing'

      first = undeploy_step(input: { 'UndeployConfig' => { 'OnConcurrentDeploy' => 'cancel' } })
      expect(first).to eq(Status: :deploy_active, OnConcurrentDeploy: 'cancel', Reported: false)
      expect(world.deploy_events).to be_empty

      world.item['deploy_asg_name'] = ''
      expect(undeploy_step).to include(Status: :complete, Reported: true)
      expect(phases).to eq([%w[undeploy started], %w[undeploy completed]])
    end

    it 'puts no started event when it loses the row to a deploy that starts after it read it' do
      # The row says a deploy is running, but Start read it before that.
      world.item['deploy_asg_name'] = 'thezoo-racing'
      allow_any_instance_of(Deployomat::Config).to receive(:deploy_asg).and_return('')

      expect { undeploy_step }.to raise_error(Aws::DynamoDB::Errors::ConditionalCheckFailedException)
      expect(world.deploy_events).to be_empty
    end

    it 'ends unreported, and still undeploys, when EventBridge will not take the event' do
      world.fail_with(:put_events, 'InternalException')

      expect(undeploy_step).to eq(Status: :complete, Reported: false)
      expect(world.item).to be_empty
    end

    it 'puts nothing when the run started on a definition that passes no ExecutionArn' do
      expect(undeploy_step(arn: nil)).to eq(Status: :complete, Reported: false)
      expect(world.deploy_events).to be_empty
    end

    it 'reports an ending nothing decided from its Report step, with Start\'s status in the error' do
      result = undeploy_step(step: 'Report', input: base_event.merge('StartResult' => { 'Status' => 'bogus' }))

      expect(result).to eq(Status: 'fail', Error: ['Unexpected result from Start: "bogus"'], Reported: true)
      expect(world.deploy_events).to contain_exactly(
        include('kind' => 'undeploy', 'phase' => 'failed', 'step' => 'Report', 'errors' => result[:Error])
      )
    end
  end

  describe 'SkipNotifications' do
    let(:input) { base_event.merge('DeployConfig' => { 'SkipNotifications' => true }) }

    it 'is carried by undeploy and cancel events, as the status path read it' do
      world.with_template.with_production
      undeploy_step(input: input)
      expect(world.deploy_events.map { |e| e['skip_notifications'] }).to eq([true, true])

      world.requests.clear
      expect(cancel_step('Report', input: input.merge('StartResult' => 'fail'))).to include(Reported: true)
      expect(world.deploy_events).to contain_exactly(include('kind' => 'cancel', 'skip_notifications' => true))
    end

    it 'is false when the input has none' do
      world.with_template.with_production
      undeploy_step

      expect(world.deploy_events.map { |e| e['skip_notifications'] }).to eq([false, false])
    end
  end

  describe 'a top-level cancel' do
    before do
      world.with_template.with_production
      step('Rollout', rollout_event(start, step_size: 50))
      world.requests.clear
    end

    it 'puts started from Start and completed from Finish' do
      expect(cancel_step('Start')).to eq(:wait)
      expect(phases).to eq([%w[cancel started]])
      expect(world.deploy_events.first).to include('step' => 'Start', 'ami' => nil, 'event_id' => 'exec-c/started')

      expect(cancel_step('Finish')).to eq(Status: :complete, Reported: true)
      expect(phases).to eq([%w[cancel started], %w[cancel completed]])
      expect(world.deploy_events.last).to include('step' => 'Finish', 'status' => 'complete')
    end

    it 'ends unreported, and still cancels, when EventBridge will not take the event' do
      cancel_step('Start')
      world.fail_with(:put_events, 'InternalException')

      expect(cancel_step('Finish')).to eq(Status: :complete, Reported: false)
      expect(world.item).to include('deploy_asg_name' => '')
    end

    it 'reports a Finish that finds nothing to cancel as failed' do
      cancel_step('Start')
      cancel_step('Finish')
      world.requests.clear

      result = cancel_step('Finish')

      expect(result).to include(Status: :fail, Reported: true)
      expect(world.deploy_events).to contain_exactly(
        include('phase' => 'failed', 'errors' => [match(/No deployment of thezoo in .* active/)])
      )
    end
  end

  describe 'a cancel that another execution started' do
    let(:nested) { base_event.merge(Deployomat::DeployEvent::PARENT_KEY => parent_arn) }

    before do
      world.with_template.with_production
      step('Rollout', rollout_event(start, step_size: 50))
      world.requests.clear
    end

    it 'puts nothing from Start or Finish, which leave their results as they were' do
      expect(cancel_step('Start', input: nested)).to eq(:wait)
      expect(cancel_step('Finish', input: nested)).to eq(Status: :complete, Reported: false)

      expect(world.deploy_events).to be_empty
      expect(world.item).to include('deploy_asg_name' => '')
    end

    it 'puts nothing from Report either' do
      result = cancel_step('Report', input: nested.merge('StartResult' => 'fail'))

      expect(result).to include(Status: 'fail', Reported: false)
      expect(world.deploy_events).to be_empty
    end
  end

  describe 'a cancel with nothing to cancel' do
    it 'puts no started event, and its Report step puts the failed one' do
      world.with_template.with_production

      expect(cancel_step('Start')).to eq(:fail)
      expect(world.deploy_events).to be_empty

      result = cancel_step('Report', input: base_event.merge('StartResult' => 'fail'))

      expect(result).to include(Status: 'fail', Reported: true)
      expect(world.deploy_events).to contain_exactly(
        include('kind' => 'cancel', 'phase' => 'failed', 'step' => 'Report',
                'errors' => ["No deployment of #{service} in #{slug} active"])
      )
    end

    it 'names an unexpected Start result when it is not the one it knows' do
      result = cancel_step('Report', input: base_event.merge('StartResult' => 'sideways'))

      expect(result[:Error]).to eq(['Unexpected result from Start: "sideways"'])
    end
  end
end
