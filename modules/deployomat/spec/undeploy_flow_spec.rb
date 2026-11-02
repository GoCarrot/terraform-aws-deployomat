# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LambdaFunctions::Handler, '.undeploy' do
  include_context 'with deploy world'

  def undeploy(config = nil)
    event = base_event.merge('DeployId' => 'exec-u', 'AllInput' => { 'UndeployConfig' => config })
    LambdaFunctions::Handler.undeploy(event: event, context: nil)
  end

  describe 'a web service' do
    let!(:production_asg) { world.with_template.with_production.item['production_asg_name'] }
    let(:production_rule) { world.rules.find { |r| r[:priority] == '10' } }

    it 'destroys the ASG, its rules and target group, then the row' do
      rule_id = production_rule[:rule_arn]

      expect(undeploy).to eq(Status: :complete)

      expect(world.calls(:delete_auto_scaling_group)).to eq(
        [{ auto_scaling_group_name: production_asg, force_delete: true }]
      )
      expect(world.calls(:delete_rule)).to eq([{ rule_arn: rule_id }])
      expect(world.calls(:delete_target_group)).to eq([{ target_group_arn: DeployWorld::PRODUCTION_TG }])
      expect(world.item).to be_empty
    end

    it 'reports a deploy it can see in the row' do
      world.item['deploy_asg_name'] = 'thezoo-racing'

      expect(undeploy).to eq(Status: :deploy_active, OnConcurrentDeploy: 'fail')
      expect(world.calls(:delete_auto_scaling_group)).to be_empty
    end

    it 'fails its condition when a deploy starts after it read the row' do
      config = Deployomat::Config.new(account_canonical_slug: slug, service_name: service,
                                      deploy_id: 'undeploy-exec-u')
      # deploy_id stays put, so only the deploy_asg_name clause can fail the condition.
      world.item['deploy_asg_name'] = 'thezoo-racing'

      expect { Deployomat::Undeploy.new(config, undeploy_config: nil).call }.to raise_error(
        Aws::DynamoDB::Errors::ConditionalCheckFailedException
      )
      expect(world.calls(:delete_auto_scaling_group)).to be_empty
    end
  end

  describe 'a batch service' do
    let(:ssm_params) { super().except(listener_param) }

    it 'destroys the ASG and the row, leaving the load balancer alone' do
      production_asg = world.with_template(target_group: false).with_production.item['production_asg_name']

      expect(undeploy).to eq(Status: :complete)

      expect(world.calls(:delete_auto_scaling_group)).to eq(
        [{ auto_scaling_group_name: production_asg, force_delete: true }]
      )
      expect(world.calls(:delete_target_group)).to be_empty
      expect(world.calls(:delete_rule)).to be_empty
      expect(world.item).to be_empty
    end
  end
end
