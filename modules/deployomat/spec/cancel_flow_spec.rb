# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LambdaFunctions::Handler, '.cancel' do
  include_context 'with deploy world'

  def cancel(name)
    event = base_event.merge('DeployId' => 'exec-c', 'Step' => name)
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

      expect(cancel('Finish')).to eq(Status: :complete)

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

      expect(cancel('Finish')).to eq(Status: :complete)

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
      expect(cancel('Finish')).to eq(Status: :complete)

      expect(world.asgs).to include(old_asg)
      expect(world.calls(:delete_auto_scaling_group)).to eq(
        [{ auto_scaling_group_name: new_asg_name, force_delete: true }]
      )
      expect(world.calls(:delete_target_group)).to be_empty
      expect(world.calls(:delete_rule)).to be_empty
      expect(world.item).to include('production_asg_name' => old_asg, 'deploy_asg_name' => '')
    end
  end
end
