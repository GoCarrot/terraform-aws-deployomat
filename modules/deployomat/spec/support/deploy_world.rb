# frozen_string_literal: true

# A small stateful fake of the AWS accounts a deploy touches: the Deployomat DynamoDB
# row, ASGs, target groups, listener rules, launch templates.
#
# Config is rebuilt on every Lambda invocation, so state has to live outside it: the row
# written by assert_start_deploy has to come back from the next get_item, and a
# describe_rules after modify_rule has to show the modified weights.
#
# Everything goes through the SDK's stubbed clients, so every request is run through the
# SDK's param validation. Describe responses carry the read-only fields real AWS returns
# (rule_arn, is_default, global_timeout, policy_arn...) so code that sends a response
# back as a request without stripping them raises here, as it would for real.
class DeployWorld
  PREFIX = '/teak/dev'
  ORG = 'teak'
  LISTENER_ARN = 'arn:aws:elasticloadbalancing:us-east-1:111111111111:listener/app/zoo/1/2'
  EXEMPLAR_TG = 'arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/thezoo-template/aaa'
  PRODUCTION_TG = 'arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/thezoo-20260101/bbb'
  DEFAULT_TG = 'arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/default/ccc'
  HOST = 'zoo.example.com'

  # Every conditional write Config makes, restated as ruby. Keyed on literal expressions,
  # not the Config constants, so a changed guard raises here instead of following along
  # unnoticed. Attributes come through the request's expression_attribute_names: the
  # names map is as much a part of the guard as the expression is.
  UNOWNED_OR_OURS = lambda { |attr, values|
    attr['#DEPLOY_ID'].nil? || attr['#DEPLOY_ID'] == values[':old_deploy_id']
  }
  OURS = ->(attr, values) { attr['#DEPLOY_ID'] == values[':deploy_id'] }
  NO_DEPLOY_ASG = ->(attr) { attr['#DEPLOY_ASG'].to_s.empty? }

  GUARDS = {
    ['SET #DEPLOY_ID = :new_deploy_id',
     '#DEPLOY_ID = :old_deploy_id AND attribute_exists(#DEPLOY_ASG) AND #DEPLOY_ASG <> :empty'] =>
      ->(attr, values) { attr['#DEPLOY_ID'] == values[':old_deploy_id'] && !NO_DEPLOY_ASG[attr] },

    ['SET #DEPLOY_ID = :new_deploy_id, #DEPLOY_ASG = :deploy_asg',
     '(attribute_not_exists(#DEPLOY_ID) OR #DEPLOY_ID = :old_deploy_id) AND ' \
     '(attribute_not_exists(#DEPLOY_ASG) OR #DEPLOY_ASG = :empty) AND ' \
     '(attribute_not_exists(#UNDEPLOY_STATE) OR #UNDEPLOY_STATE <> :undeploying)'] =>
      lambda { |attr, values|
        UNOWNED_OR_OURS[attr, values] && NO_DEPLOY_ASG[attr] && attr['#UNDEPLOY_STATE'] != 'undeploying'
      },

    ['SET #DEPLOY_ID = :new_deploy_id, #UNDEPLOY_STATE = :undeploying',
     '(attribute_not_exists(#DEPLOY_ID) OR #DEPLOY_ID = :old_deploy_id) AND ' \
     '(attribute_not_exists(#DEPLOY_ASG) OR #DEPLOY_ASG = :empty) AND ' \
     '(#UNDEPLOY_STATE = :allow OR #UNDEPLOY_STATE = :undeploying)'] =>
      lambda { |attr, values|
        UNOWNED_OR_OURS[attr, values] && NO_DEPLOY_ASG[attr] && %w[allow undeploying].include?(attr['#UNDEPLOY_STATE'])
      },

    [nil,
     '(attribute_not_exists(#DEPLOY_ID) OR #DEPLOY_ID = :deploy_id) AND ' \
     '(attribute_not_exists(#UNDEPLOY_STATE) OR #UNDEPLOY_STATE = :undeploying)'] =>
      lambda { |attr, values|
        (attr['#DEPLOY_ID'].nil? || OURS[attr, values]) &&
          (attr['#UNDEPLOY_STATE'].nil? || attr['#UNDEPLOY_STATE'] == 'undeploying')
      },

    ['SET #DEPLOY_ID = :deploy_id', '#DEPLOY_ID = :deploy_id'] => OURS,

    ['SET #PROD_ASG = :prod_asg, #DEPLOY_ASG = :empty, #UNDEPLOY_STATE = :undeploy_state',
     '#DEPLOY_ID = :deploy_id'] => OURS,

    ['SET #DEPLOY_ASG = :empty', '#DEPLOY_ID = :deploy_id'] => OURS
  }.freeze

  attr_reader :requests, :item, :rules, :target_groups, :asgs, :healthy, :failures

  def initialize(slug:, service:)
    @primary_key = "#{slug}.#{service}"
    @service = service
    @requests = []
    @failures = {}
    @item = { 'id' => @primary_key }
    @asgs = {}
    @rules = []
    @target_groups = {}
    @tags = {}
    @healthy = Hash.new(0)
    @launch_template_version = 7
    @counter = 0
  end

  # Request params for every call to an operation, in order.
  def calls(operation)
    requests.select { |(name, _)| name == operation }.map(&:last)
  end

  # Make every call to an operation fail with an AWS error code, e.g. 'ValidationError'.
  def fail_with(operation, code)
    failures[operation] = code
  end

  def rule(arn)
    rules.find { |r| r[:rule_arn] == arn }
  end

  # Template ASG, its target group, and the exemplar rule (priority 40_010, so 10 in production).
  # Without a target group it's a batch service: no target groups or rules of its own.
  def with_template(hooks: true, policies: true, warm_pool: true, metrics: true, target_group: true)
    @hooks = hooks
    @policies = policies
    asgs["#{@service}-template"] = {
      auto_scaling_group_name: "#{@service}-template",
      launch_template: { launch_template_id: 'lt-0abc', launch_template_name: "#{@service}-template",
                         version: '$Latest' },
      min_size: 0, max_size: 0, desired_capacity: 0, default_cooldown: 300, created_time: Time.at(0),
      availability_zones: %w[us-east-1a us-east-1b],
      vpc_zone_identifier: 'subnet-a,subnet-b',
      service_linked_role_arn: 'arn:aws:iam::111111111111:role/aws-service-role/autoscaling.amazonaws.com/asg',
      health_check_type: 'ELB', health_check_grace_period: 120, max_instance_lifetime: 604_800,
      termination_policies: %w[OldestInstance],
      target_group_arns: target_group ? [EXEMPLAR_TG] : [], instances: [],
      tags: [
        asg_tag("#{ORG}:min_size", '1'), asg_tag("#{ORG}:max_size", '6'), asg_tag('Environment', 'dev')
      ],
      enabled_metrics: []
    }
    if metrics
      asgs["#{@service}-template"][:enabled_metrics] = [{ metric: 'GroupDesiredCapacity', granularity: '1Minute' },
                                                        { metric: 'GroupInServiceInstances', granularity: '1Minute' }]
    end
    asgs["#{@service}-template"][:warm_pool_configuration] = { pool_state: 'Stopped' } if warm_pool
    target_groups[DEFAULT_TG] = build_target_group(DEFAULT_TG, 'default')
    rules << default_rule
    return self unless target_group

    target_groups[EXEMPLAR_TG] = build_target_group(EXEMPLAR_TG, "#{@service}-template")
    @tags[EXEMPLAR_TG] = [{ key: 'Environment', value: 'dev' }]
    add_rule(40_010, EXEMPLAR_TG)
    self
  end

  # A deployed production ASG with three instances, its target group, and its rule.
  def with_production
    name = "#{@service}-20260101T000000Z"
    web = !asgs.fetch("#{@service}-template")[:target_group_arns].empty?
    asgs[name] = asgs.fetch("#{@service}-template").merge(
      auto_scaling_group_name: name, min_size: 2, max_size: 6, desired_capacity: 3,
      target_group_arns: web ? [PRODUCTION_TG] : [],
      launch_template: { launch_template_id: 'lt-0abc', launch_template_name: "#{@service}-template", version: '6' },
      instances: Array.new(3) { |i| instance("i-0#{i}") }
    )
    if web
      target_groups[PRODUCTION_TG] = build_target_group(PRODUCTION_TG, "#{@service}-20260101")
      @tags[PRODUCTION_TG] = [{ key: 'Managed', value: 'Deployomat' }]
      add_rule(10, PRODUCTION_TG)
    end
    item['production_asg_name'] = name
    item['deploy_id'] = 'deploy-previous'
    item['undeploy_state'] = 'allow'
    self
  end

  def stubs
    {
      dynamodb: dynamodb_stubs, autoscaling: autoscaling_stubs, elasticloadbalancingv2: elb_stubs,
      ec2: ec2_stubs, eventbridge: eventbridge_stubs
    }.transform_values { |responses| { stub_responses: with_failures(responses) } }
  end

  private

  def with_failures(responses)
    responses.to_h do |operation, stub|
      [operation, lambda do |ctx|
        next stub.call(ctx) unless failures.key?(operation)

        record(ctx)
        failures[operation]
      end]
    end
  end

  def record(ctx)
    # The SDK fills in idempotency tokens; they're noise.
    requests << [ctx.operation_name.to_sym, copy(ctx.params.except(:client_token))]
  end

  def copy(obj)
    Marshal.load(Marshal.dump(obj))
  end

  def conditional_failure
    'ConditionalCheckFailedException'
  end

  def dynamodb_stubs
    {
      get_item: lambda do |ctx|
        record(ctx)
        { item: copy(item) }
      end,
      update_item: ->(ctx) { update_item(ctx) },
      delete_item: ->(ctx) { delete_item(ctx) }
    }
  end

  def update_item(ctx)
    guarded_write(ctx) do |values, names|
      ctx.params[:update_expression].delete_prefix('SET ').split(', ').each do |assignment|
        name, value = assignment.split(' = ')
        item[names.fetch(name)] = values.fetch(value)
      end
      { attributes: copy(item) }
    end
  end

  def delete_item(ctx)
    guarded_write(ctx) do
      deleted = copy(item)
      item.clear
      { attributes: deleted }
    end
  end

  def guarded_write(ctx)
    record(ctx)
    params = ctx.params
    guard = GUARDS.fetch([params[:update_expression], params[:condition_expression]]) do
      raise "DeployWorld: no guard for #{params[:update_expression]} IF #{params[:condition_expression]}"
    end
    # The dynamodb client rewrites plain values to {s: 'x'} before a stub sees them.
    values = params[:expression_attribute_values].transform_values { |v| v.is_a?(Hash) ? v.values.first : v }
    names = params[:expression_attribute_names]

    return conditional_failure unless guard.call(->(name) { item[names.fetch(name)] }, values)

    yield values, names
  end

  def autoscaling_stubs
    {
      describe_auto_scaling_groups: lambda do |ctx|
        record(ctx)
        names = ctx.params[:auto_scaling_group_names]
        { auto_scaling_groups: copy(asgs.values_at(*names).compact) }
      end,
      describe_lifecycle_hooks: lambda do |ctx|
        record(ctx)
        { lifecycle_hooks: @hooks ? [lifecycle_hook(ctx.params[:auto_scaling_group_name])] : [] }
      end,
      describe_policies: lambda do |ctx|
        record(ctx)
        { scaling_policies: @policies ? [scaling_policy(ctx.params[:auto_scaling_group_name])] : [] }
      end,
      create_auto_scaling_group: ->(ctx) { create_asg(ctx) },
      update_auto_scaling_group: lambda do |ctx|
        record(ctx)
        asgs[ctx.params[:auto_scaling_group_name]][:min_size] = ctx.params[:min_size]
        {}
      end,
      delete_auto_scaling_group: lambda do |ctx|
        record(ctx)
        asgs.delete(ctx.params[:auto_scaling_group_name])
        {}
      end,
      enable_metrics_collection: ->(ctx) { record(ctx) && {} },
      put_warm_pool: ->(ctx) { record(ctx) && {} },
      put_scaling_policy: ->(ctx) { record(ctx) && { policy_arn: 'arn:aws:autoscaling:policy/new' } }
    }
  end

  def create_asg(ctx)
    record(ctx)
    params = ctx.params
    asgs[params[:auto_scaling_group_name]] = {
      auto_scaling_group_name: params[:auto_scaling_group_name],
      launch_template: params[:launch_template].merge(launch_template_name: "#{@service}-template"),
      min_size: params[:min_size], max_size: params[:max_size], desired_capacity: params[:min_size],
      vpc_zone_identifier: params[:vpc_zone_identifier], health_check_type: params[:health_check_type],
      target_group_arns: params[:target_group_arns] || [], instances: [],
      tags: params[:tags].map { |tag| asg_tag(tag[:key], tag[:value]) },
      enabled_metrics: [], default_cooldown: 300, created_time: Time.at(0), availability_zones: %w[us-east-1a]
    }
    {}
  end

  def elb_stubs
    {
      describe_target_groups: lambda do |ctx|
        record(ctx)
        { target_groups: copy(target_groups.values_at(*ctx.params[:target_group_arns])) }
      end,
      describe_target_group_attributes: lambda do |ctx|
        record(ctx)
        { attributes: [{ key: 'deregistration_delay.timeout_seconds', value: '30' },
                       { key: 'stickiness.enabled', value: 'false' }] }
      end,
      describe_tags: lambda do |ctx|
        record(ctx)
        { tag_descriptions: ctx.params[:resource_arns].map do |arn|
          { resource_arn: arn, tags: copy(@tags.fetch(arn, [{ key: 'Environment', value: 'dev' }])) }
        end }
      end,
      create_target_group: ->(ctx) { create_target_group(ctx) },
      modify_target_group_attributes: ->(ctx) { record(ctx) && {} },
      delete_target_group: lambda do |ctx|
        record(ctx)
        target_groups.delete(ctx.params[:target_group_arn])
        {}
      end,
      describe_target_health: lambda do |ctx|
        record(ctx)
        arn = ctx.params[:target_group_arn]
        { target_health_descriptions: Array.new([3, healthy[arn]].max) do |i|
          { target: { id: "i-0#{i}", port: 80 }, target_health: { state: i < healthy[arn] ? 'healthy' : 'initial' } }
        end }
      end,
      describe_rules: lambda do |ctx|
        record(ctx)
        found = ctx.params[:rule_arns] ? ctx.params[:rule_arns].map { |arn| rule(arn) } : rules
        { rules: copy(found) }
      end,
      create_rule: ->(ctx) { create_rule(ctx) },
      modify_rule: ->(ctx) { modify_rule(ctx) },
      delete_rule: lambda do |ctx|
        record(ctx)
        rules.delete(rule(ctx.params[:rule_arn]))
        {}
      end
    }
  end

  def create_target_group(ctx)
    record(ctx)
    name = ctx.params[:name]
    arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/#{name}/new"
    created = build_target_group(arn, name)
    target_groups[arn] = created
    @tags[arn] = ctx.params[:tags]
    { target_groups: [copy(created)] }
  end

  def create_rule(ctx)
    record(ctx)
    params = ctx.params
    @counter += 1
    created = {
      rule_arn: "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener-rule/app/zoo/1/2/new#{@counter}",
      priority: params[:priority].to_s, is_default: false,
      conditions: with_values(params[:conditions]), actions: params[:actions]
    }
    rules << created
    @tags[created[:rule_arn]] = params[:tags]
    { rules: [copy(created)] }
  end

  def modify_rule(ctx)
    record(ctx)
    params = ctx.params
    existing = rule(params[:rule_arn])
    existing[:conditions] = with_values(params[:conditions]) if params[:conditions]
    existing[:actions] = params[:actions] if params[:actions]
    { rules: [copy(existing)] }
  end

  def ec2_stubs
    {
      create_launch_template_version: lambda do |ctx|
        record(ctx)
        @launch_template_version += 1
        { launch_template_version: { launch_template_id: ctx.params[:launch_template_id],
                                     version_number: @launch_template_version } }
      end,
      describe_launch_template_versions: lambda do |ctx|
        record(ctx)
        versions = ctx.params[:versions].map { |v| v == '$Latest' ? @launch_template_version : v.to_i }
        { launch_template_versions: versions.map do |number|
          { launch_template_id: ctx.params[:launch_template_id], version_number: number }
        end }
      end,
      modify_launch_template: lambda do |ctx|
        record(ctx)
        { launch_template: { launch_template_id: ctx.params[:launch_template_id],
                             default_version_number: ctx.params[:default_version].to_i } }
      end
    }
  end

  def eventbridge_stubs
    {
      describe_rule: lambda do |ctx|
        record(ctx)
        'ResourceNotFoundException'
      end
    }
  end

  def asg_tag(key, value)
    { resource_id: 'asg', resource_type: 'auto-scaling-group', key: key, value: value, propagate_at_launch: true }
  end

  def instance(id)
    { instance_id: id, availability_zone: 'us-east-1a', lifecycle_state: 'InService',
      health_status: 'Healthy', protected_from_scale_in: false }
  end

  def lifecycle_hook(asg_name)
    {
      lifecycle_hook_name: 'drain', auto_scaling_group_name: asg_name,
      lifecycle_transition: 'autoscaling:EC2_INSTANCE_TERMINATING', heartbeat_timeout: 300,
      global_timeout: 3600, default_result: 'CONTINUE',
      notification_target_arn: 'arn:aws:sqs:us-east-1:111111111111:drain',
      role_arn: 'arn:aws:iam::111111111111:role/drain'
    }
  end

  def scaling_policy(asg_name)
    {
      auto_scaling_group_name: asg_name, policy_name: 'cpu',
      policy_arn: 'arn:aws:autoscaling:us-east-1:111111111111:scalingPolicy:1:policyName/cpu',
      policy_type: 'TargetTrackingScaling', estimated_instance_warmup: 120, enabled: true,
      step_adjustments: [],
      target_tracking_configuration: {
        predefined_metric_specification: { predefined_metric_type: 'ASGAverageCPUUtilization' },
        target_value: 50.0, disable_scale_in: false
      },
      alarms: [{ alarm_name: 'TargetTracking-cpu-high', alarm_arn: 'arn:aws:cloudwatch:alarm:cpu-high' }]
    }
  end

  def build_target_group(arn, name)
    {
      target_group_arn: arn, target_group_name: name, protocol: 'HTTP', protocol_version: 'HTTP1', port: 80,
      vpc_id: 'vpc-0abc', health_check_protocol: 'HTTP', health_check_port: 'traffic-port',
      health_check_enabled: true, health_check_interval_seconds: 30, health_check_timeout_seconds: 5,
      healthy_threshold_count: 3, unhealthy_threshold_count: 3, health_check_path: '/health',
      matcher: { http_code: '200' }, load_balancer_arns: ['arn:aws:elasticloadbalancing:loadbalancer/app/zoo/1'],
      target_type: 'instance', ip_address_type: 'ipv4'
    }
  end

  # Rules come back from describe_rules with the condition's values both under
  # `values` and under the type-specific config. Requests only accept one of the two.
  def with_values(conditions)
    conditions.map do |cond|
      cond.merge(values: cond.dig(:host_header_config, :values))
    end
  end

  def host_condition
    { field: 'host-header', values: [HOST], host_header_config: { values: [HOST] } }
  end

  # A forward to one target group comes back with both target_group_arn and forward_config.
  def forward(target_group_arn)
    {
      type: 'forward', order: 1, target_group_arn: target_group_arn,
      forward_config: {
        target_groups: [{ target_group_arn: target_group_arn, weight: 1 }],
        target_group_stickiness_config: { enabled: false }
      }
    }
  end

  def add_rule(priority, target_group_arn)
    @counter += 1
    rule = {
      rule_arn: "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener-rule/app/zoo/1/2/r#{@counter}",
      priority: priority.to_s, is_default: false,
      conditions: [host_condition], actions: [forward(target_group_arn)]
    }
    rules << rule
    @tags[rule[:rule_arn]] = [{ key: 'Environment', value: 'dev' }]
    rule
  end

  def default_rule
    { rule_arn: 'arn:aws:elasticloadbalancing:us-east-1:111111111111:listener-rule/app/zoo/1/2/default',
      priority: 'default', is_default: true, conditions: [], actions: [forward(DEFAULT_TG)] }
  end
end
