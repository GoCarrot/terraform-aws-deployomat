# frozen_string_literal: true

require_relative 'spec_helper'

# Drives the deploy Lambda one Step at a time, the way state_machines/deploy.json does,
# against a stateful fake of the account (support/deploy_world.rb).
RSpec.describe LambdaFunctions::Handler, '.deploy' do
  include_context 'with stubbed aws'

  let(:world) { DeployWorld.new(slug: slug, service: service) }
  let(:prefix) { DeployWorld::PREFIX }
  let(:deploy_config) { { 'TrafficShiftPerStep' => 50, 'WaitPerStep' => 1, 'BakeTime' => 10 } }
  let(:ami) { 'ami-0123456789' }
  let(:ssm_params) do
    {
      "/omat/account_registry/#{slug}" => JSON.generate(account_info),
      "#{prefix}/roles/Deployomat" => 'arn:aws:iam::111111111111:role/teak/service-role/Deployomat',
      "#{prefix}/config/#{service}/listener_arns" => JSON.generate([DeployWorld::LISTENER_ARN])
    }
  end

  before do
    ENV.delete('DEPLOYOMAT_AMI_SEARCH_OWNERS')
    Aws.config.update(world.stubs)
    allow_any_instance_of(Deployomat::Asg).to receive(:sleep)
  end

  # The handlers puts a running commentary.
  around do |example|
    original = $stdout
    $stdout = StringIO.new # rubocop:disable RSpec/ExpectOutput
    example.run
  ensure
    $stdout = original # rubocop:disable RSpec/ExpectOutput
  end

  def step(name, event = {})
    base = { 'AccountCanonicalSlug' => slug, 'ServiceName' => service, 'DeployId' => 'exec-1', 'Step' => name }
    LambdaFunctions::Handler.deploy(event: base.merge(event), context: nil)
  end

  def start(config: deploy_config, ami_id: ami)
    step('Start', 'AmiId' => ami_id, 'AllInput' => { 'DeployConfig' => config })
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

  describe 'first deploy' do
    let(:template_options) { {} }

    before { world.with_template(**template_options) }

    it 'goes Start -> Bake -> Finish' do
      started = start
      expect(started).to include(Status: :success, WaitForBakeTime: 10, AllowUndeploy: true)
      expect(started[:NewTargetGroupArn]).to eq(new_tg_arn)
      expect(started[:RuleIds].length).to eq(1)

      bake = { 'TargetGroupArn' => started[:NewTargetGroupArn], 'RuleIds' => started[:RuleIds], 'BakeTime' => 10 }
      expect(loop_step('Bake', bake)).to eq(Status: :complete)

      finished = step('Finish', 'AllowUndeploy' => started[:AllowUndeploy],
                                'AutomaticUndeployMinutes' => started[:AutomaticUndeployMinutes])

      expect(finished).to eq(Status: :complete)
      expect(world.item).to include('production_asg_name' => new_asg_name, 'deploy_asg_name' => '')
      expect(world.calls(:delete_auto_scaling_group)).to be_empty
      expect(world.calls(:modify_launch_template)).to eq(
        [{ launch_template_id: 'lt-0abc', default_version: '8' }]
      )
    end

    it 'makes a launch template version for the AMI' do
      start

      expect(world.calls(:create_launch_template_version)).to eq(
        [{ launch_template_data: { image_id: ami }, launch_template_id: 'lt-0abc', source_version: '$Latest' }]
      )
    end

    it 'clones the target group without its identity and tags it managed' do
      start

      created = world.calls(:create_target_group).first
      expect(created).to include(port: 80, vpc_id: 'vpc-0abc', health_check_path: '/health', target_type: 'instance')
      expect(created[:name]).to match(/\Athezoo-\d{8}T\d{6}Z\z/)
      expect(created).not_to include(:target_group_arn, :target_group_name, :load_balancer_arns)
      expect(created[:tags]).to include(key: 'Managed', value: 'Deployomat')
      expect(world.calls(:modify_target_group_attributes).first).to include(target_group_arn: new_tg_arn)
    end

    it 'clones the ASG from the template' do
      start

      created = world.calls(:create_auto_scaling_group).first
      expect(created).to include(
        vpc_zone_identifier: 'subnet-a,subnet-b', health_check_type: 'ELB', max_size: 6, min_size: 1,
        target_group_arns: [new_tg_arn], launch_template: { launch_template_id: 'lt-0abc', version: '8' }
      )
      expect(created[:lifecycle_hook_specification_list]).to match(
        [hash_including(lifecycle_hook_name: 'drain', heartbeat_timeout: 300)]
      )
      expect(created[:lifecycle_hook_specification_list].first).not_to include(:global_timeout,
                                                                               :auto_scaling_group_name)
    end

    it 'sends tags without the ASG-specific identity, and flips Managed' do
      start

      tags = world.calls(:create_auto_scaling_group).first[:tags]
      expect(tags).to include(
        { key: 'Environment', value: 'dev', propagate_at_launch: true },
        { key: 'Managed', value: 'Deployomat' }
      )
      expect(tags).to all(satisfy { |tag| (tag.keys & %i[resource_id resource_type]).empty? })
    end

    it 'copies metrics, warm pool and scaling policies to the new ASG' do
      start

      expect(world.calls(:enable_metrics_collection)).to eq(
        [{ auto_scaling_group_name: new_asg_name, granularity: '1Minute',
           metrics: %w[GroupDesiredCapacity GroupInServiceInstances] }]
      )
      expect(world.calls(:put_warm_pool)).to eq([{ auto_scaling_group_name: new_asg_name, pool_state: 'Stopped' }])

      policy = world.calls(:put_scaling_policy).first
      expect(policy).to include(auto_scaling_group_name: new_asg_name, policy_name: 'cpu',
                                policy_type: 'TargetTrackingScaling')
      expect(policy).not_to include(:policy_arn, :alarms, :step_adjustments)
    end

    it 'creates the rule at the exemplar priority minus the offset, pointing at the new target group' do
      started = start

      created = world.calls(:create_rule).first
      expect(created).to include(listener_arn: DeployWorld::LISTENER_ARN, priority: 10)
      expect(created).not_to include(:rule_arn, :is_default)
      expect(created[:conditions]).to eq([{ field: 'host-header',
                                            host_header_config: { values: [DeployWorld::HOST] } }])
      expect(created[:tags]).to include(key: 'Managed', value: 'Deployomat')
      expect(weights(started[:RuleIds].first)).to eq(new_tg_arn => 1)
      expect(world.rule(started[:RuleIds].first)[:actions].first).to include(target_group_arn: new_tg_arn)
    end

    context 'when the template has no hooks, policies, metrics or warm pool' do
      let(:template_options) { { hooks: false, policies: false, warm_pool: false, metrics: false } }

      it 'skips them on the clone' do
        start

        expect(world.calls(:put_warm_pool)).to be_empty
        expect(world.calls(:put_scaling_policy)).to be_empty
        expect(world.calls(:enable_metrics_collection)).to be_empty
        expect(world.calls(:create_auto_scaling_group).first[:lifecycle_hook_specification_list]).to eq([])
      end
    end
  end

  describe 'rolling deploy' do
    before { world.with_template.with_production }

    let(:production_rule) { world.rules.find { |r| r[:priority] == '10' } }
    let(:started) { start }

    it 'goes Start -> CheckHealthy -> Rollout -> Coalesce -> Bake -> Finish' do
      old_asg = world.item['production_asg_name']
      expect(started).to include(
        Status: :wait_healthy, OldTargetGroupArn: DeployWorld::PRODUCTION_TG, NewTargetGroupArn: new_tg_arn,
        MinHealthy: 3, TrafficShiftPerStep: 50, RuleIds: [production_rule[:rule_arn]]
      )
      expect(weights(production_rule[:rule_arn])).to eq(DeployWorld::PRODUCTION_TG => 100, new_tg_arn => 0)

      world.healthy[new_tg_arn] = 3
      healthy = loop_step('CheckHealthy', 'WaitTime' => started[:WaitForHealthyTime], 'MinHealthy' => 3,
                                          'TargetGroupArn' => new_tg_arn)
      expect(healthy).to eq(Status: :complete)

      rollout = { 'StepSize' => 50, 'StepDelay' => 1, 'RuleIds' => started[:RuleIds], 'TargetGroupArn' => new_tg_arn,
                  'OldTargetGroupArn' => DeployWorld::PRODUCTION_TG }
      expect(step('Rollout', rollout)).to eq(Status: :wait, Wait: 1, Progress: 50)
      expect(weights(production_rule[:rule_arn])).to eq(DeployWorld::PRODUCTION_TG => 50, new_tg_arn => 50)
      expect(step('Rollout', rollout.merge('StepResult' => { 'Progress' => 50 }))).to eq(Status: :complete)
      expect(weights(production_rule[:rule_arn])).to eq(DeployWorld::PRODUCTION_TG => 0, new_tg_arn => 100)

      coalesce = { 'TargetGroupArn' => new_tg_arn, 'RuleIds' => started[:RuleIds] }
      expect(step('Coalesce', coalesce)).to eq(Status: :complete)
      expect(weights(production_rule[:rule_arn])).to eq(new_tg_arn => 100)

      bake = coalesce.merge('BakeTime' => started[:WaitForBakeTime])
      expect(loop_step('Bake', bake)).to eq(Status: :complete)

      finished = step('Finish', 'AllowUndeploy' => started[:AllowUndeploy],
                                'AutomaticUndeployMinutes' => started[:AutomaticUndeployMinutes])

      expect(finished).to eq(Status: :complete)
      expect(world.item).to include('production_asg_name' => new_asg_name)
      expect(world.calls(:delete_auto_scaling_group)).to eq([{ auto_scaling_group_name: old_asg, force_delete: true }])
      expect(world.calls(:delete_target_group)).to eq([{ target_group_arn: DeployWorld::PRODUCTION_TG }])
    end

    it 'sizes the new ASG to the production instance count' do
      started

      expect(world.calls(:create_auto_scaling_group).first).to include(min_size: 3, max_size: 6)
    end

    it 'prevents scale-in on production by pinning its minimum to its current size' do
      started

      expect(world.calls(:update_auto_scaling_group)).to eq(
        [{ auto_scaling_group_name: world.item['production_asg_name'], min_size: 3 }]
      )
    end

    it 'modifies the production rule without the fields modify_rule rejects' do
      started

      modified = world.calls(:modify_rule).first
      expect(modified.keys).to contain_exactly(:rule_arn, :conditions, :actions)
      expect(modified[:conditions]).to eq(
        [{ field: 'host-header', host_header_config: { values: [DeployWorld::HOST] } }]
      )
      expect(modified[:actions].first.keys).to contain_exactly(:type, :order, :forward_config)
    end

    it 'keeps the stickiness config when it coalesces' do
      started
      step('Coalesce', 'TargetGroupArn' => new_tg_arn, 'RuleIds' => started[:RuleIds])

      sent = world.calls(:modify_rule).last
      expect(sent[:actions].first[:forward_config]).to eq(
        target_groups: [{ target_group_arn: new_tg_arn, weight: 100 }],
        target_group_stickiness_config: { enabled: false }
      )
      expect(sent[:actions].first).not_to include(:target_group_arn)
    end

    it 'waits until enough targets are healthy, then gives up after the timeout' do
      started
      world.healthy[new_tg_arn] = 1
      event = { 'MinHealthy' => 3, 'TargetGroupArn' => new_tg_arn, 'WaitTime' => 30 }

      expect(step('CheckHealthy', event)).to eq(Status: :wait, Wait: 15, RemainingTime: 15)
      expect(step('CheckHealthy', event.merge('StepResult' => { 'RemainingTime' => 15 }))).to eq(
        Status: :wait, Wait: 15, RemainingTime: 0
      )
      expect(step('CheckHealthy', event.merge('StepResult' => { 'RemainingTime' => 0 }))).to eq(
        Status: :fail, Error: ['Service did not become healthy. Have 1 of 3 instances.']
      )
    end
  end

  describe 'start' do
    before { world.with_template }

    it 'fails when no AMI is given' do
      result = start(ami_id: '')

      expect(result).to eq(Status: :fail, Error: ['No AMI specified'])
      expect(world.calls(:create_auto_scaling_group)).to be_empty
    end

    it 'fails on a negative bake time' do
      result = start(config: { 'BakeTime' => -1 })

      expect(result).to eq(Status: :fail, Error: ['bake_time must be greater than zero'])
    end

    it 'fails when the template ASG is missing' do
      world.asgs.delete("#{service}-template")

      expect(start).to eq(Status: :fail, Error: ["Could not load #{service}-template. Is ServiceName correct?"])
    end

    it 'reports a deploy already in progress without touching anything' do
      world.item.merge!('deploy_id' => 'deploy-other', 'deploy_asg_name' => 'thezoo-other')

      expect(start).to eq(Status: :deploy_active, OnConcurrentDeploy: 'rollback')
      expect(world.calls(:create_launch_template_version)).to be_empty
    end

    it 'reports an undeploy in progress' do
      world.item.merge!('deploy_id' => 'undeploy-other', 'undeploy_state' => 'undeploying')

      expect(start).to eq(Status: :undeploying, Error: ['Undeploy of thezoo in Dev in progress.'])
    end

    it 'removes the target group it made when the ASG will not clone' do
      Aws.config[:autoscaling][:stub_responses][:create_auto_scaling_group] = lambda do |ctx|
        world.requests << [:create_auto_scaling_group, ctx.params]
        'ValidationError'
      end

      result = start

      expect(result[:Status]).to eq(:fail)
      expect(result[:Error].first).to match(/\AError cloning ASG to thezoo-.*Aws::AutoScaling::Errors::ValidationError/)
      expect(world.calls(:create_auto_scaling_group).length).to eq(3)
      made = world.calls(:modify_target_group_attributes).first[:target_group_arn]
      expect(world.calls(:delete_target_group)).to eq([{ target_group_arn: made }])
    end

    it 'reuses a launch template version for $launchtemplate:$LatestMinus:2' do
      result = start(ami_id: '$launchtemplate:$LatestMinus:2')

      expect(result[:Status]).to eq(:success)
      expect(world.calls(:describe_launch_template_versions)).to eq(
        [{ launch_template_id: 'lt-0abc', versions: ['$Latest'] }, { launch_template_id: 'lt-0abc', versions: ['5'] }]
      )
      expect(world.calls(:create_launch_template_version)).to be_empty
      expect(world.calls(:create_auto_scaling_group).first[:launch_template]).to eq(
        launch_template_id: 'lt-0abc', version: '5'
      )
    end

    it 'reuses an explicit $launchtemplate version' do
      start(ami_id: '$launchtemplate:3')

      expect(world.calls(:describe_launch_template_versions)).to eq(
        [{ launch_template_id: 'lt-0abc', versions: ['3'] }]
      )
      expect(world.calls(:create_auto_scaling_group).first[:launch_template][:version]).to eq('3')
    end

    it 'resolves a $name-prefix to the newest matching AMI' do
      ENV['DEPLOYOMAT_AMI_SEARCH_OWNERS'] = '111111111111'
      Aws.config[:ec2][:stub_responses][:describe_images] = {
        images: [
          { image_id: 'ami-old', name: 'zoo-1', creation_date: '2026-01-01' },
          { image_id: 'ami-new', name: 'zoo-2', creation_date: '2026-02-01' },
          { image_id: 'ami-other', name: 'other-3', creation_date: '2026-03-01' }
        ]
      }

      start(ami_id: '$name-prefix:zoo-')

      expect(world.calls(:create_launch_template_version).first[:launch_template_data]).to eq(image_id: 'ami-new')
    end
  end

  describe 'aborting' do
    before do
      world.with_template.with_production
      rule_ids
      world.item['deploy_id'] = 'deploy-someone-else'
    end

    let(:started) { start }
    let(:rule_ids) { started[:RuleIds] }

    it 'stops CheckHealthy' do
      expect(step('CheckHealthy', 'MinHealthy' => 3, 'TargetGroupArn' => new_tg_arn, 'WaitTime' => 30)).to eq(
        Status: :deploy_aborted
      )
    end

    it 'stops Rollout before shifting any traffic' do
      result = step('Rollout', 'StepSize' => 50, 'StepDelay' => 1, 'RuleIds' => rule_ids,
                               'TargetGroupArn' => new_tg_arn, 'OldTargetGroupArn' => DeployWorld::PRODUCTION_TG)

      expect(result).to eq(Status: :deploy_aborted)
      expect(world.calls(:modify_rule).length).to eq(1)
    end

    it 'stops Coalesce' do
      expect(step('Coalesce', 'TargetGroupArn' => new_tg_arn, 'RuleIds' => rule_ids)).to eq(Status: :deploy_aborted)
      expect(world.calls(:modify_rule).length).to eq(1)
    end

    it 'stops Finish without replacing production' do
      expect(step('Finish', 'AllowUndeploy' => true)).to eq(Status: :deploy_aborted)
      expect(world.calls(:delete_auto_scaling_group)).to be_empty
    end
  end
end
