# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LambdaFunctions::Handler, '.cancel' do
  include_context 'with deploy world'

  def cancel(name)
    event = base_event.merge('DeployId' => 'exec-c', 'Step' => name, 'ExecutionArn' => CANCEL_EXECUTION_ARN,
                             'AllInput' => base_event)
    LambdaFunctions::Handler.cancel(event: event, context: nil)
  end

  # A cancel a deploy started for a newer deploy carries its parent's execution ARN; a manual one doesn't.
  def cancel_from(by_deploy, name)
    input = by_deploy ? base_event.merge('AWS_STEP_FUNCTIONS_STARTED_BY_EXECUTION_ID' => DEPLOY_EXECUTION_ARN) : base_event
    event = base_event.merge('DeployId' => 'exec-c', 'Step' => name, 'ExecutionArn' => CANCEL_EXECUTION_ARN,
                             'AllInput' => input)
    LambdaFunctions::Handler.cancel(event: event, context: nil)
  end

  describe 'a rolling deploy mid-rollout' do
    let(:old_asg) { world.item['production_asg_name'] }
    let(:started) { start }
    let(:rule_id) { started[:RuleIds].first }

    before do
      world.with_template.with_production
      old_asg
      step('Rollout', rollout_event(started, step_size: 50))
    end

    it 'coalesces back to production, then removes the deploy' do
      expect(weights(rule_id)).to eq(DeployWorld::PRODUCTION_TG => 50, new_tg_arn => 50)
      deploy_tg = new_tg_arn

      expect(cancel('Start')).to eq(:wait)

      expect(weights(rule_id)).to eq(DeployWorld::PRODUCTION_TG => 100)
      expect(world.item['deploy_id']).to eq('cancel-exec-c')

      expect(cancel('Finish')).to eq(Status: :complete, Reported: true)

      expect(world.calls(:delete_auto_scaling_group)).to eq(
        [{ auto_scaling_group_name: new_asg_name, force_delete: true }]
      )
      expect(world.calls(:delete_target_group)).to eq([{ target_group_arn: deploy_tg }])
      expect(world.item).to include('production_asg_name' => old_asg, 'deploy_asg_name' => '',
                                    'undeploy_state' => 'allow')
    end

    it 'sends a coalesced rule without the fields modify_rule rejects' do
      cancel('Start')

      sent = world.calls(:modify_rule).last
      expect(sent.keys).to contain_exactly(:rule_arn, :conditions, :actions)
      expect(sent[:actions].first[:forward_config]).to eq(
        target_groups: [{ target_group_arn: DeployWorld::PRODUCTION_TG, weight: 100 }],
        target_group_stickiness_config: { enabled: false }
      )
    end

    it 'restores scale-in on production from its min_size tag' do
      cancel('Start')
      cancel('Finish')

      expect(world.calls(:update_auto_scaling_group).last).to eq(auto_scaling_group_name: old_asg, min_size: 1)
    end

    it 'lets the next Start proceed' do
      cancel('Start')
      cancel('Finish')

      expect(start(deploy_id: 'exec-2')[:Status]).to eq(:wait_healthy)
    end
  end

  describe 'a first deploy' do
    before { world.with_template }

    it 'deletes the rule it made and resets the row' do
      started = start
      rule_id = started[:RuleIds].first

      expect(cancel('Start')).to eq(:success)

      expect(world.calls(:delete_rule)).to eq([{ rule_arn: rule_id }])
      expect(world.rule(rule_id)).to be_nil

      expect(cancel('Finish')).to eq(Status: :complete, Reported: true)

      expect(world.asgs.keys).to eq(["#{service}-template"])
      expect(new_tg_arn).to be_nil
      expect(world.item).to include('production_asg_name' => '', 'deploy_asg_name' => '')
    end
  end

  describe 'a batch service' do
    let(:ssm_params) { super().except(listener_param) }

    it 'destroys the new ASG and leaves production and the load balancer alone' do
      world.with_template(target_group: false).with_production
      old_asg = world.item['production_asg_name']
      start

      expect(cancel('Start')).to eq(:success)
      expect(cancel('Finish')).to eq(Status: :complete, Reported: true)

      expect(world.asgs).to include(old_asg)
      expect(world.calls(:delete_auto_scaling_group)).to eq(
        [{ auto_scaling_group_name: new_asg_name, force_delete: true }]
      )
      expect(world.calls(:delete_target_group)).to be_empty
      expect(world.calls(:delete_rule)).to be_empty
      expect(world.item).to include('production_asg_name' => old_asg, 'deploy_asg_name' => '')
    end
  end

  # The old deploy trips on its next conditional write once a cancel has its lock. Its Finish comes after
  # Bake, and by then a newer deploy may already hold the row, so the reason has to be on the row.
  describe 'the old deploy finding out it lost the lock after a newer deploy has started' do
    let(:parent) { false }
    let(:superseding) { 'Deploy was cancelled due to a superseding deploy.' }

    before do
      world.with_template.with_production
      start
      cancel_from(parent, 'Start')
      cancel_from(parent, 'Finish')
      start(deploy_id: 'exec-2')
    end

    def finish_old_deploy
      step('Finish', 'AllowUndeploy' => true)
    end

    context 'when a manual cancel took the lock' do
      it 'records the cancel as manual on the row' do
        expect(world.item).to include('deploy_id' => 'deploy-exec-2', 'cancel_by' => 'manual')
      end

      it 'ends the old deploy aborted with the cancel wording' do
        expect(finish_old_deploy).to eq(Status: :deploy_aborted, Error: ['Deploy was cancelled.'], Reported: true)
        expect(world.deploy_events.last).to include('phase' => 'aborted', 'errors' => ['Deploy was cancelled.'])
      end
    end

    context 'when a newer deploy\'s cancel took the lock' do
      let(:parent) { true }

      it 'records the cancel as a deploy cancel on the row' do
        expect(world.item).to include('deploy_id' => 'deploy-exec-2', 'cancel_by' => 'deploy')
      end

      it 'ends the old deploy aborted with the superseding wording' do
        expect(finish_old_deploy).to eq(Status: :deploy_aborted, Error: [superseding], Reported: true)
        expect(world.deploy_events.last).to include('phase' => 'aborted', 'errors' => [superseding])
      end
    end
  end

  # Two deploys cancel the same deploy: whoever writes the row's deploy_id last owns the cancel, and
  # the other's next conditional write fails. That is the loser being superseded, not a failure.
  describe 'losing the deploy lock to another cancel' do
    let(:superseded) do
      { Status: :deploy_aborted, Error: ['Deploy was cancelled due to a superseding deploy.'], Reported: false }
    end

    # Takes the row over just before the nth write to it.
    def take_over_before_write(nth)
      writes = 0
      world.before_call(:update_item) do
        writes += 1
        world.item['deploy_id'] = 'cancel-other' if writes == nth
      end
    end

    before do
      world.with_template.with_production
      start
    end

    it 'ends Start as superseded when the claim itself loses' do
      take_over_before_write(1)

      expect(cancel('Start')).to eq(:superseded)
      expect(world.deploy_events.map { |e| e['kind'] }).to eq(['deploy'])
    end

    it 'ends Start as superseded when the row is taken after the claim' do
      take_over_before_write(2)

      expect(cancel('Start')).to eq(:superseded)
    end

    it 'ends Finish as superseded when the row is taken mid-cancel, and leaves the cleanup to the new owner' do
      cancel('Start')
      world.item['deploy_id'] = 'cancel-other'

      expect(cancel('Finish')).to eq(superseded)
      expect(world.calls(:delete_auto_scaling_group)).to be_empty
    end

    it 'ends Finish as superseded when the row is taken before the final write' do
      cancel('Start')
      take_over_before_write(3)

      expect(cancel('Finish')).to eq(superseded)
    end
  end
end
