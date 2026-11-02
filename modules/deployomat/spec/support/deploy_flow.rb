# frozen_string_literal: true

# Drives the Lambdas one Step at a time, the way state_machines/ do, against a stateful
# fake of the account (deploy_world.rb).
RSpec.shared_context 'with deploy world' do
  include_context 'with stubbed aws'

  let(:world) { DeployWorld.new(slug: slug, service: service) }
  let(:prefix) { DeployWorld::PREFIX }
  let(:deploy_config) { { 'TrafficShiftPerStep' => 50, 'WaitPerStep' => 1, 'BakeTime' => 10 } }
  let(:ami) { 'ami-0123456789' }
  let(:listener_param) { "#{prefix}/config/#{service}/listener_arns" }
  let(:ssm_params) do
    {
      "/omat/account_registry/#{slug}" => JSON.generate(account_info),
      "#{prefix}/roles/Deployomat" => 'arn:aws:iam::111111111111:role/teak/service-role/Deployomat',
      listener_param => JSON.generate([DeployWorld::LISTENER_ARN])
    }
  end

  before do
    Aws.config.update(world.stubs)
    allow_any_instance_of(Deployomat::Asg).to receive(:sleep)
    # The handlers narrate with puts.
    allow($stdout).to receive(:puts)
  end

  def base_event
    { 'AccountCanonicalSlug' => slug, 'ServiceName' => service }
  end

  def step(name, event = {})
    event = base_event.merge('DeployId' => 'exec-1', 'Step' => name).merge(event)
    LambdaFunctions::Handler.deploy(event: event, context: nil)
  end

  def start(config: deploy_config, ami_id: ami, deploy_id: 'exec-1')
    step('Start', 'AmiId' => ami_id, 'AllInput' => { 'DeployConfig' => config }, 'DeployId' => deploy_id)
  end

  # What the loop-wait state machine does: call again with the last result until it stops waiting.
  def loop_step(name, event)
    result = step(name, event)
    20.times do
      return result unless result[:Status] == :wait

      # Step Functions hands the last result back as JSON.
      result = step(name, event.merge('StepResult' => JSON.parse(JSON.generate(result))))
    end
    raise "#{name} still waiting after 20 steps: #{result}"
  end

  def rollout_event(started, step_size:)
    { 'StepSize' => step_size, 'StepDelay' => 1, 'RuleIds' => started[:RuleIds],
      'TargetGroupArn' => started[:NewTargetGroupArn], 'OldTargetGroupArn' => started[:OldTargetGroupArn] }
  end

  def new_asg_name
    world.calls(:create_auto_scaling_group).first.fetch(:auto_scaling_group_name)
  end

  def new_tg_arn
    world.target_groups.keys.find { |arn| arn.end_with?('/new') }
  end

  def weights(rule_arn)
    world.rule(rule_arn)[:actions].first[:forward_config][:target_groups].to_h do |tg|
      [tg[:target_group_arn], tg[:weight]]
    end
  end
end
