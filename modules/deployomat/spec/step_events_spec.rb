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

  def events_after_started
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
      expect(events_after_started).to contain_exactly(include(expected))
    end

    it 'reports an undeploy in progress' do
      world.with_template
      world.item.merge!('deploy_id' => 'undeploy-other', 'undeploy_state' => 'undeploying')

      expect(start_run).to include(Status: :undeploying, Reported: true)
      expect(events_after_started.first)
        .to include('phase' => 'failed', 'status' => 'undeploying',
                    'errors' => ['Undeploy of thezoo in Dev in progress.'])
    end

    it 'reports a concurrent deploy only when set to fail, since on cancel the run comes back to Start' do
      world.with_template
      world.item.merge!('deploy_id' => 'deploy-other', 'deploy_asg_name' => 'thezoo-other')

      expect(start_run).to include(Status: :deploy_active, Reported: false)
      expect(world.deploy_events).to be_empty

      expect(start_run(config: deploy_config.merge('OnConcurrentDeploy' => 'fail'))).to include(Reported: true)
      expect(events_after_started).to contain_exactly(
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
      expect(events_after_started).to contain_exactly(include(expected))
    end

    it 'reports a Coalesce a newer deploy superseded as aborted, saying so' do
      rule_ids = started[:RuleIds]
      world.item.merge!('deploy_id' => 'deploy-someone-else', 'cancel_by' => 'deploy')

      expect(step('Coalesce', from_start.merge('TargetGroupArn' => new_tg_arn, 'RuleIds' => rule_ids)))
        .to eq(Status: :deploy_aborted, Error: [Deployomat::DeployEvent::Reporter::CANCELLED], Reported: true)
      expect(events_after_started).to contain_exactly(
        include('phase' => 'aborted', 'step' => 'Coalesce', 'errors' => [Deployomat::DeployEvent::Reporter::CANCELLED])
      )
    end

    it 'reports a Coalesce a manual cancel ended as aborted, without the superseding wording' do
      rule_ids = started[:RuleIds]
      world.item.merge!('deploy_id' => 'cancel-exec-c', 'cancel_by' => 'manual')

      expect(step('Coalesce', from_start.merge('TargetGroupArn' => new_tg_arn, 'RuleIds' => rule_ids)))
        .to eq(Status: :deploy_aborted, Error: ['Deploy was cancelled.'], Reported: true)
      expect(events_after_started.map { |e| e.values_at('phase', 'errors') })
        .to eq([['aborted', ['Deploy was cancelled.']]])
    end

    it 'treats a row with no cancel_by as a manual cancel, for rows written before cancel_by existed' do
      rule_ids = started[:RuleIds]
      world.item['deploy_id'] = 'deploy-someone-else'

      expect(step('Coalesce', from_start.merge('TargetGroupArn' => new_tg_arn, 'RuleIds' => rule_ids)))
        .to eq(Status: :deploy_aborted, Error: ['Deploy was cancelled.'], Reported: true)
    end

    it 'puts a progress event after each Rollout shift, without ending the run' do
      rollout = from_start.merge('StepSize' => 60, 'StepDelay' => 1, 'RuleIds' => started[:RuleIds],
                                 'TargetGroupArn' => new_tg_arn, 'OldTargetGroupArn' => DeployWorld::PRODUCTION_TG)

      expect(step('Rollout', rollout)).to eq(Status: :wait, Wait: 1, Progress: 60, Reported: false)
      expect(step('Rollout', rollout.merge('StepResult' => { 'Progress' => 60 })))
        .to eq(Status: :complete, Reported: false)
      expect(events_after_started.map { |e| e.values_at('step', 'status', 'progress', 'ami') }).to eq(
        [['Rollout', 'wait', 'Shifted 60% of traffic to the new ASG', ami],
         ['Rollout', 'complete', 'Shifted 100% of traffic to the new ASG', ami]]
      )
      expect(events_after_started.map { |e| e['event_id'] }.uniq.length).to eq(2)
    end

    def progress_lines
      events_after_started.map { |e| e.values_at('phase', 'step', 'status', 'progress') }
    end

    it 'puts a progress event when CheckHealthy has enough healthy instances, and none while waiting' do
      started
      event = from_start.merge('MinHealthy' => 2, 'TargetGroupArn' => new_tg_arn, 'WaitTime' => 60)

      world.healthy[new_tg_arn] = 1
      expect(step('CheckHealthy', event)).to include(Status: :wait, Reported: false)
      world.healthy[new_tg_arn] = 3
      expect(step('CheckHealthy', event)).to eq(Status: :complete, Reported: false)
      expect(progress_lines).to eq([['progress', 'CheckHealthy', 'complete', '3 instances healthy (needed 2)']])
    end

    it 'puts a progress event when Coalesce has moved the traffic' do
      expect(step('Coalesce', from_start.merge('TargetGroupArn' => new_tg_arn, 'RuleIds' => started[:RuleIds])))
        .to eq(Status: :complete, Reported: false)
      expect(progress_lines).to eq([['progress', 'Coalesce', 'complete', 'Took the old ASG off the listener rules']])
    end

    it 'puts one progress event as Bake starts, and none when it ends' do
      started
      bake = from_start.merge('BakeTime' => 600)

      expect(step('Bake', bake)).to eq(Status: :wait, Wait: 600, RemainingTime: 0, Reported: false)
      expect(step('Bake',
                  bake.merge('StepResult' => { 'RemainingTime' => 0 }))).to eq(Status: :complete, Reported: false)
      expect(progress_lines).to eq([['progress', 'Bake', 'wait', 'Baking for 600s']])
    end

    it 'returns the same step results when the progress events do not land' do
      started
      world.fail_with(:put_events, 'AccessDeniedException')
      healthy = from_start.merge('MinHealthy' => 1, 'TargetGroupArn' => new_tg_arn, 'WaitTime' => 0)
      world.healthy[new_tg_arn] = 1

      expect do
        expect(step('CheckHealthy', healthy)).to eq(Status: :complete, Reported: false)
        expect(step('Bake', from_start.merge('BakeTime' => 600)))
          .to eq(Status: :wait, Wait: 600, RemainingTime: 0, Reported: false)
        expect(step('Coalesce', from_start.merge('TargetGroupArn' => new_tg_arn, 'RuleIds' => started[:RuleIds])))
          .to eq(Status: :complete, Reported: false)
      end.to output(/put_events/).to_stderr
    end

    it 'leaves a result no step reported unmarked, so the status-event readers report it' do
      started

      expect(step('Bake', from_start.merge('BakeTime' => 0, 'StepResult' => { 'RemainingTime' => 0 })))
        .to eq(Status: :complete, Reported: false)
      expect(events_after_started).to be_empty
    end

    it 'reports Finish as completed, after everything Finish does' do
      started
      result = step('Finish', from_start.merge('AllowUndeploy' => true))

      expect(result).to eq(Status: :complete, Reported: true)
      expect(events_after_started).to contain_exactly(include('phase' => 'completed', 'ami' => ami))
      expect(world.requests.last.first).to eq(:put_events)
    end

    it 'puts nothing when Finish raises' do
      started
      world.fail_with(:modify_launch_template, 'ValidationError')

      expect { step('Finish', from_start.merge('AllowUndeploy' => true)) }.to raise_error(Aws::EC2::Errors::ValidationError)
      expect(events_after_started).to be_empty
    end
  end

  it 'is not Reported, and puts nothing, for a run on the definition before this one' do
    world.with_template.with_production
    start_run
    world.item['deploy_id'] = 'deploy-someone-else'

    expect(step('Finish', 'AllowUndeploy' => true, 'ExecutionArn' => nil))
      .to eq(Status: :deploy_aborted, Error: ['Deploy was cancelled.'], Reported: false)
    expect(events_after_started).to be_empty
  end

  it 'is not Reported when EventBridge rejects the event' do
    world.fail_with(:put_events, 'AccessDeniedException')

    result = nil
    expect { result = start_run }.to output(/put_events/).to_stderr
    expect(result).to include(Status: :fail, Reported: false)
  end
end
