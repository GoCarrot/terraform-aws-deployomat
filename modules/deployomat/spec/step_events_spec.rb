# frozen_string_literal: true

require_relative 'spec_helper'

# Each step puts its own finished event where it decides the run is over, with what deploy.json
# passes it: the deploy run's ExecutionArn (also inside loop-wait), and Start's Ami and SkipNotifications.
RSpec.describe LambdaFunctions::Handler, '.deploy step events' do
  include_context 'with deploy world'

  let(:execution_arn) { 'arn:aws:states:us-east-1:232340377988:execution:deploy:exec-1' }
  let(:resolved) { { 'Id' => ami, 'Tags' => { 'BuildCommit' => '09c4f525' } } }
  # What deploy.json adds to a later step's input from $$.Execution.Id and $.StartDeploy.
  let(:from_start) do
    { 'ExecutionArn' => execution_arn, 'AmiId' => ami, 'Ami' => resolved, 'SkipNotifications' => false }
  end

  def start_run(config: deploy_config, ami_id: ami)
    step('Start', 'AmiId' => ami_id, 'AllInput' => { 'DeployConfig' => config }, 'ExecutionArn' => execution_arn)
  end

  def finished_events
    world.deploy_events.reject { |e| e['phase'] == 'started' }
  end

  describe 'Start' do
    it 'reports a failure it returns, naming the AmiId it was given' do
      world.images['ami-0123456789'] = { tags: { 'BuildCommit' => 'abc1234' } }

      result = start_run

      expect(result).to include(Status: :fail, Reported: true)
      expected = {
        'event_id' => 'exec-1/failed', 'execution_arn' => execution_arn, 'ami' => ami,
        'ami_tags' => { 'BuildCommit' => 'abc1234' },
        'errors' => ["Could not load #{service}-template. Is ServiceName correct?"],
        'step' => 'Start', 'status' => 'fail'
      }
      expect(finished_events).to contain_exactly(include(expected))
    end

    it 'reports an undeploy in progress' do
      world.with_template
      world.item.merge!('deploy_id' => 'undeploy-other', 'undeploy_state' => 'undeploying')

      expect(start_run).to include(Status: :undeploying, Reported: true)
      expect(finished_events.first)
        .to include('phase' => 'failed', 'status' => 'undeploying',
                    'errors' => ['Undeploy of thezoo in Dev in progress.'])
    end

    it 'reports a concurrent deploy only when set to fail, since on cancel the run comes back to Start' do
      world.with_template
      world.item.merge!('deploy_id' => 'deploy-other', 'deploy_asg_name' => 'thezoo-other')

      expect(start_run).to include(Status: :deploy_active, Reported: false)
      expect(world.deploy_events).to be_empty

      expect(start_run(config: deploy_config.merge('OnConcurrentDeploy' => 'fail'))).to include(Reported: true)
      expect(finished_events).to contain_exactly(
        include('phase' => 'failed', 'status' => 'deploy_active', 'errors' => [Deployomat::StartDeploy::CONCURRENT])
      )
    end

    it 'puts failed after started when Start fails once it has the AMI, naming that AMI' do
      world.with_template
      world.images[ami] = { tags: { 'BuildCommit' => 'abc1234' } }
      world.fail_with(:create_auto_scaling_group, 'ValidationError')
      world.before_call(:put_events) { |ctx| sleep 0.2 if ctx.params[:entries].first[:detail].include?('"started"') }

      expect(start_run).to include(Status: :fail, Reported: true)
      expect(world.deploy_events.map { |e| e.values_at('phase', 'ami_tags') })
        .to eq([['started', { 'BuildCommit' => 'abc1234' }], ['failed', { 'BuildCommit' => 'abc1234' }]])
    end

    it 'hands the later steps what they report with' do
      world.with_template

      result = start_run

      expect(result).to include(Ami: { Id: ami, Tags: {} }, SkipNotifications: false, Reported: false)
    end
  end

  describe 'the steps after Start' do
    before { world.with_template.with_production }

    let(:started) { start_run }

    it 'reports an unhealthy CheckHealthy as failed, with the deploy run, not the loop-wait run' do
      started
      event = from_start.merge('MinHealthy' => 3, 'TargetGroupArn' => new_tg_arn, 'WaitTime' => 0,
                               'StepResult' => { 'RemainingTime' => 0 })

      expect(step('CheckHealthy', event)).to include(Status: :fail, Reported: true)
      expected = {
        'event_id' => 'exec-1/failed', 'execution_arn' => execution_arn, 'ami' => ami,
        'ami_tags' => { 'BuildCommit' => '09c4f525' },
        'errors' => ['Service did not become healthy. Have 0 of 3 instances.'], 'step' => 'CheckHealthy'
      }
      expect(finished_events).to contain_exactly(include(expected))
    end

    it 'reports a superseded Coalesce as aborted' do
      rule_ids = started[:RuleIds]
      world.item['deploy_id'] = 'deploy-someone-else'

      expect(step('Coalesce', from_start.merge('TargetGroupArn' => new_tg_arn, 'RuleIds' => rule_ids)))
        .to eq(Status: :deploy_aborted, Reported: true)
      expect(finished_events).to contain_exactly(
        include('phase' => 'aborted', 'step' => 'Coalesce', 'errors' => [Deployomat::DeployEvent::Reporter::CANCELLED])
      )
    end

    it 'leaves a result no step reported unmarked, so the status-event readers report it' do
      started

      expect(step('Bake', from_start.merge('BakeTime' => 0, 'StepResult' => { 'RemainingTime' => 0 })))
        .to eq(Status: :complete, Reported: false)
      expect(finished_events).to be_empty
    end

    it 'reports Finish as completed, after everything Finish does' do
      started
      result = step('Finish', from_start.merge('AllowUndeploy' => true))

      expect(result).to eq(Status: :complete, Reported: true)
      expect(finished_events).to contain_exactly(include('phase' => 'completed', 'ami' => ami))
      expect(world.requests.last.first).to eq(:put_events)
    end

    it 'puts nothing when Finish raises' do
      started
      world.fail_with(:modify_launch_template, 'ValidationError')

      expect { step('Finish', from_start.merge('AllowUndeploy' => true)) }.to raise_error(Aws::EC2::Errors::ValidationError)
      expect(finished_events).to be_empty
    end
  end

  it 'is not Reported, and puts nothing, for a run on the definition before this one' do
    world.with_template.with_production
    start_run
    world.item['deploy_id'] = 'deploy-someone-else'

    expect(step('Finish', 'AllowUndeploy' => true, 'ExecutionArn' => nil))
      .to eq(Status: :deploy_aborted, Reported: false)
    expect(finished_events).to be_empty
  end

  it 'is not Reported when EventBridge rejects the event' do
    world.fail_with(:put_events, 'AccessDeniedException')

    result = nil
    expect { result = start_run }.to output(/put_events/).to_stderr
    expect(result).to include(Status: :fail, Reported: false)
  end
end
