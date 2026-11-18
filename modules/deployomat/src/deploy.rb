# frozen_string_literal: true

# Copyright 2021 Teak.io, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative 'lib'
require_relative 'deploy_event'

module Deployomat
  ACTIVE_DEPLOY_MSG = "Asserting active deploy"
  NOT_ACTIVE_MSG = "No longer active deploy."
  ACTIVE_ASSERT_MSG = "Asserted active"

  class StartDeploy
    extend Forwardable

    DEFAULT_BAKE_TIME = 30
    DEFAULT_TRAFFIC_SHIFT_PER_STEP = 5
    DEFAULT_WAIT_PER_STEP = 15
    DEFAULT_HEALTH_TIMEOUT = 300
    DEFAULT_ON_CONCURRENT_DEPLOY = 'rollback'

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :ami_id, :new_asg_name, :bake_time, :health_timeout, :new_tg_name,
                :traffic_shift_per_step, :wait_per_step, :allow_undeploy, :automatic_undeploy_minutes

    GREATER_THAN_ZERO = %i[traffic_shift_per_step].freeze
    NOT_NEGATIVE = %i[bake_time wait_per_step health_timeout].freeze

    def initialize(config, ami_id:, deploy_config:, execution_arn: nil)
      deploy_config = deploy_config || {}
      @config = config
      @ami_id = ami_id
      @execution_arn = execution_arn
      @skip_notifications = deploy_config['SkipNotifications'] == true
      @new_asg_name = "#{service_name}-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      @new_tg_name = "#{service_name[0...15]}-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"

      # TODO: These should be configurable.
      @bake_time = deploy_config.fetch('BakeTime', DEFAULT_BAKE_TIME)
      @traffic_shift_per_step = deploy_config.fetch('TrafficShiftPerStep', DEFAULT_TRAFFIC_SHIFT_PER_STEP)
      @wait_per_step = deploy_config.fetch('WaitPerStep', DEFAULT_WAIT_PER_STEP)
      @health_timeout = deploy_config.fetch('HealthTimeout', DEFAULT_HEALTH_TIMEOUT)
      @on_concurrent_deploy = deploy_config.fetch('OnConcurrentDeploy', DEFAULT_ON_CONCURRENT_DEPLOY)
      @allow_undeploy = deploy_config.fetch('AllowUndeploy', @config.account_environment != 'production')
      @automatic_undeploy_minutes = deploy_config.fetch('AutomaticUndeployMinutes', nil)
      @errors = []
    end

    # The started report runs on its own thread, alongside the target group and ASG clones,
    # and is joined before the Lambda returns or raises so the put isn't frozen halfway.
    def call
      response = start
      ami = @started&.value
      ami ? response.merge(Ami: ami, SkipNotifications: @skip_notifications) : response
    ensure
      @started&.join
    end

  private

    def start
      if ami_id.nil? || ami_id.empty?
        error "No AMI specified"
      end

      GREATER_THAN_ZERO.each do |check_attr|
        if send(check_attr) <= 0
          error "#{check_attr} must be greater than zero"
        end
      end

      NOT_NEGATIVE.each do |check_attr|
        if send(check_attr) < 0
          error "#{check_attr} must not be negative"
        end
      end

      if @automatic_undeploy_minutes && !@allow_undeploy
        error "Cannot request an automatic undeploy without allowing undeploy"
      end

      asg = Asg.new(@config)

      template_asg_name = "#{service_name}-template"
      puts "Fetching template asg..."
      template_asg = asg.get(template_asg_name)

      if !template_asg
        error "Could not load #{template_asg_name}. Is ServiceName correct?"
      end

      if !@errors.empty?
        puts "Failing due to invalid configuration."
        return error_response
      end

      production_asg = @config.production_asg&.yield_self { |name| asg.get(name) }

      begin
        puts "Setting deploying asg #{new_asg_name}..."
        @config.assert_start_deploy(new_asg_name)
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        @config.reload
        deploy_asg = @config.deploy_asg
        if deploy_asg && !deploy_asg.empty?
          puts "Deployment of #{service_name} in #{account_name} still in progress"
          return { Status: :deploy_active, OnConcurrentDeploy: @on_concurrent_deploy }
        elsif @config.undeploying?
          error "Undeploy of #{service_name} in #{account_name} in progress."
          return error_response(:undeploying)
        else
          error "Failed to assert active deploy for unknown reason."
          return error_response
        end
      end

      ec2 = Ec2.new(@config)
      launch_template_id = template_asg.launch_template.launch_template_id
      if ami_id.start_with?('$')
        puts "Identifying ami id or launch template version for #{ami_id}"
        command = process_command(ec2, template_asg, ami_id)
      else
        command = [:ami, ami_id]
      end

      lt =
        case command
        in [:ami, id]
          puts "Creating launch template version..."
          lt = ec2.create_launch_template_version(launch_template_id, id)
          puts "Created launch template version #{lt.version_number}"
          lt
        in [:launch_template, launch_template]
          puts "Reusing launch template version #{launch_template.version_number}"
          launch_template
        end

      report_started(lt.launch_template_data&.image_id)

      elbv2 = ElbV2.new(@config)
      # TODO: Support multiple target groups per asg.
      exemplar_tg_arn = template_asg.target_group_arns&.first
      new_target_group_arn = nil
      if exemplar_tg_arn
        puts "Cloning target group..."
        new_target_group = elbv2.clone_target_group(exemplar_tg_arn, new_tg_name)
        new_target_group_arn = new_target_group.target_group_arn
        puts "Cloned target group #{new_target_group_arn}"
      end

      begin
        puts "Cloning asg..."
        asg.clone_asg(template_asg, lt, new_asg_name, production_asg&.instances&.length, new_target_group_arn)
      rescue Aws::AutoScaling::Errors::ServiceError => exc
        message = "Error cloning ASG to #{new_asg_name}. #{exc.class.name} #{exc.message}"
        puts message
        error message
        abandon_start(asg, elbv2, new_target_group_arn)
        return error_response
      end



      if production_asg
        puts ACTIVE_DEPLOY_MSG
        begin
          @config.assert_active
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          error NOT_ACTIVE_MSG
          return error_response
        end
        puts ACTIVE_ASSERT_MSG
        puts "Preventing scale-in of #{production_asg.auto_scaling_group_name}"
        asg.prevent_scale_in(production_asg)
      end

      production_tg_arn = production_asg&.target_group_arns&.first

      if exemplar_tg_arn
        listeners = params.get_list_or_json("#{prefix}/config/#{service_name}/listener_arns")
        production_rules = listeners.flat_map do |(key, listener)|
          if !listener
            listener = key
            key = nil
          end

          puts "Preparing deploy rules for #{key} listener #{listener}..."
          elbv2.prepare_deploy_rules(
            listener, production_tg_arn, exemplar_tg_arn, new_target_group_arn
          )
        end

        if production_rules.all? { |rule| rule.first == :initial }
          return {
            Status: :success, WaitForBakeTime: bake_time, RuleIds: production_rules.map { |pr| pr[1].rule_arn },
            NewTargetGroupArn: new_target_group_arn, AllowUndeploy: allow_undeploy,
            AutomaticUndeployMinutes: @automatic_undeploy_minutes
          }
        end

        production_rules.map! { |pr| pr[1].rule_arn }

        deploy_asg = asg.get(new_asg_name)
        requested_min = deploy_asg.min_size

        return {
          Status: :wait_healthy, WaitForHealthyTime: health_timeout, NewTargetGroupArn: new_target_group_arn,
          OldTargetGroupArn: production_tg_arn, MinHealthy: requested_min, TrafficShiftPerStep: traffic_shift_per_step,
          WaitPerStep: wait_per_step, RuleIds: production_rules, WaitForBakeTime: bake_time,
          AllowUndeploy: allow_undeploy, AutomaticUndeployMinutes: @automatic_undeploy_minutes
        }
      else
        return {
          Status: :success, WaitForBakeTime: bake_time, RuleIds: '', NewTargetGroupArn: '',
          AllowUndeploy: allow_undeploy, AutomaticUndeployMinutes: @automatic_undeploy_minutes
        }
      end
    end

    # This run ends here with no Rollback, so nothing else will clean up after it. Clearing
    # the row comes last: if the cleanup raises the row is still set, which is what lets
    # the state machine's Catch -> Rollback find what was left behind.
    def abandon_start(asg, elbv2, target_group_arn)
      # clone_asg can fail after the ASG exists, and the row is our only pointer to it.
      if asg.get(new_asg_name)
        puts "Destroying new asg #{new_asg_name}"
        asg.destroy(new_asg_name)
      end

      if target_group_arn
        puts "Destroying new target group #{target_group_arn}"
        elbv2.destroy_tg(target_group_arn)
      end

      begin
        puts "Clearing deploying asg #{new_asg_name}"
        @config.clear_deploy_asg
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        puts NOT_ACTIVE_MSG
      end
    end

    def process_command(ec2, template_asg, cmd)
      launch_template = template_asg.launch_template
      case cmd
      when /^\$launchtemplate:(?<lt_version>(?:[1-9][0-9]*$)|(?:\$Latest$)|(?:\$Default$)|(?:\$LatestMinus:(?<offset>[0-9]+$)))/
        match_data = $~
        lt_version = match_data[:lt_version]
        offset = match_data[:offset]
        puts "Identifying launch template version for #{lt_version}"
        # Strip off the offset for $LatestMinus, since we already extracted it into offset.
        lt_version = lt_version.split(':')[0]
        [:launch_template, ec2.launch_template_version(launch_template.launch_template_id, lt_version, offset)]
      when /^\$name\-prefix:(?<prefix>[a-zA-Z0-9\(\)\[\] \.\/\-\'\@\_]{3,128}$)/
        match_data = $~
        name_prefix = match_data[:prefix]
        puts "Identifying most recent AMI with a name starting with #{name_prefix}"
        ami = ec2.latest_ami_for_name_prefix(name_prefix)
        raise "Unable to identify an AMI starting with #{name_prefix}!" if !ami
        image_id = ami.image_id
        puts "Selected #{ami.name} : #{image_id}"
        [:ami, image_id]
      else
        raise "Unknown special command #{cmd}"
      end
    end

    def error(msg)
      puts msg
      @errors << msg
    end

    def error_response(status = :fail)
      { Status: status, Error: @errors }
    end

    # The AMI this deploy launches, whatever AmiId named it, with its tags. Report reads it
    # back from this step's result for the finished event, so the tags are looked up once.
    def report_started(resolved_ami_id)
      @started = Thread.new do
        tags = DeployEvent.ami_tags(resolved_ami_id)
        DeployEvent.publish(DeployEvent.detail(
          kind: 'deploy', phase: 'started', service: service_name, account: @config.account_canonical_slug,
          execution_arn: @execution_arn, ami: resolved_ami_id, ami_requested: ami_id, ami_tags: tags,
          skip_notifications: @skip_notifications
        ))
        { Id: resolved_ami_id, Tags: tags }
      rescue StandardError => e
        $stderr.puts("deploy event: started report failed: #{e.class}: #{e.message}")
        { Id: resolved_ami_id, Tags: {} }
      end
    end
  end

  # The one ending no Lambda of ours decides: a step raised or timed out, or returned a status
  # nothing matched, and the run rolled back through the cancel state machine. Only Step
  # Functions sees that, so this step runs after Rollback, puts the failed event with the caught
  # error, and hands back the run's outcome plus `Reported`.
  #
  # Takes the run's whole state as `all_input`, because which fields exist depends on how far
  # the run got. Needs no Config: nothing here touches the deploy's account or state.
  class ReportDeploy
    PHASES = { 'complete' => 'completed', 'deploy_aborted' => 'aborted', 'fail' => 'failed' }.freeze
    MAX_CAUSE_CHARS = 500

    def initialize(all_input:, execution_arn:)
      @all_input = all_input.is_a?(Hash) ? all_input : {}
      @execution_arn = execution_arn
    end

    def call
      outcome = @all_input['Outcome'].is_a?(Hash) ? @all_input['Outcome'] : {}
      return outcome.merge('Reported' => false) unless @all_input['ServiceName']

      reported =
        begin
          DeployEvent.publish(detail(outcome))
        rescue StandardError => e
          $stderr.puts("deploy event: could not report #{@execution_arn}: #{e.class}: #{e.message}")
          false
        end
      outcome.merge('Reported' => reported)
    end

    private

    def detail(outcome)
      requested = @all_input['AmiId']
      DeployEvent.detail(
        kind: 'deploy', phase: PHASES.fetch(outcome['Status'], 'unknown'),
        service: @all_input['ServiceName'], account: @all_input['AccountCanonicalSlug'],
        execution_arn: @execution_arn, ami_requested: requested, errors: errors(outcome),
        skip_notifications: @all_input.dig('DeployConfig', 'SkipNotifications') == true,
        **DeployEvent.ami_fields(@all_input.dig('StartDeploy', 'Ami'), requested)
      )
    end

    # A run that rolled back after a Catch carries the caught error as { Error, Cause }.
    def errors(outcome)
      errors = Array(outcome['Error'])
      return errors unless errors.empty?

      caught = @all_input['Error']
      caught.is_a?(Hash) ? [caught['Error'], cause(caught['Cause'])].compact : []
    end

    # A Lambda error's Cause is a JSON blob with a stack trace, and a failed child run's is its
    # whole execution description. Keep the message, and keep it short.
    def cause(raw)
      return nil if raw.nil?

      parsed = begin
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        nil
      end
      message = parsed.is_a?(Hash) && parsed['errorMessage'] ? parsed['errorMessage'] : raw
      message.to_s[0, MAX_CAUSE_CHARS]
    end
  end

  class CheckHealthy
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :max_wait, :min_healthy, :remaining_time, :target_group_arn, :seconds_to_wait

    def initialize(config, max_wait:, min_healthy:, target_group_arn:, remaining_time: nil)
      @config = config
      @max_wait = max_wait
      @min_healthy = min_healthy
      @remaining_time = remaining_time || max_wait
      @target_group_arn = target_group_arn

      # TODO: Make configurable and/or dynamic?
      @seconds_to_wait = 15
    end

    def call
      elbv2 = ElbV2.new(@config)

      puts ACTIVE_DEPLOY_MSG
      begin
        @config.assert_active
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        puts NOT_ACTIVE_MSG
        return { Status: :deploy_aborted }
      end
      puts ACTIVE_ASSERT_MSG

      healthy_count = elbv2.count_healthy(target_group_arn)
      puts "Waiting for #{min_healthy} healthy instances, have #{healthy_count}"

      if healthy_count >= min_healthy
        { Status: :complete }
      elsif remaining_time >= seconds_to_wait
        { Status: :wait, Wait: seconds_to_wait, RemainingTime: remaining_time - seconds_to_wait }
      else
        { Status: :fail, Error: ["Service did not become healthy. Have #{healthy_count} of #{min_healthy} instances."] }
      end
    end
  end

  class Rollout
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :step_size, :step_delay, :rule_ids, :target_group_arn, :old_target_group_arn, :progress

    def initialize(config, step_size:, step_delay:, rule_ids:, target_group_arn:, old_target_group_arn:, progress:)
      @config = config
      @step_size = step_size
      @step_delay = step_delay
      @rule_ids = rule_ids
      @target_group_arn = target_group_arn
      @old_target_group_arn = old_target_group_arn
      @progress = progress || 0
    end

    def call
      elbv2 = ElbV2.new(@config)

      production_rules = elbv2.describe_rules(rule_ids)

      total = progress + step_size
      production_rules.each do |rule|
        puts ACTIVE_DEPLOY_MSG
        begin
          @config.assert_active
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          puts NOT_ACTIVE_MSG
          return { Status: :deploy_aborted }
        end
        puts ACTIVE_ASSERT_MSG
        elbv2.shift_traffic(rule, step_size, old_target_group_arn, target_group_arn)
        puts "Shifted traffic on #{rule.rule_arn} to #{[total, 100].min}%"
      end
      if total >= 100
        { Status: :complete }
      else
        { Status: :wait, Wait: step_delay, Progress: total }
      end
    end
  end

  class Coalesce
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :rule_ids, :target_group_arn

    def initialize(config, rule_ids:, target_group_arn:)
      @config = config
      @rule_ids = rule_ids
      @target_group_arn = target_group_arn
    end

    def call
      elbv2 = ElbV2.new(@config)

      production_rules = elbv2.describe_rules(rule_ids)

      production_rules.each do |rule|
        puts ACTIVE_DEPLOY_MSG
        begin
          @config.assert_active
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          puts NOT_ACTIVE_MSG
          return { Status: :deploy_aborted }
        end
        puts ACTIVE_ASSERT_MSG
        elbv2.coalesce(rule, target_group_arn)
        puts "Coalesced traffic on #{rule.rule_arn}"
      end
      { Status: :complete }
    end
  end

  class Bake
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :rule_ids, :target_group_arn, :bake_time, :remaining_time

    def initialize(config, rule_ids:, target_group_arn:, bake_time:, remaining_time:)
      @config = config
      @rule_ids = rule_ids
      @target_group_arn = target_group_arn
      @bake_time = bake_time
      @remaining_time = remaining_time || @bake_time
    end

    def call
      if remaining_time <= 0
        { Status: :complete }
      else
        { Status: :wait, Wait: @bake_time, RemainingTime: 0 }
      end
    end
  end

  class FinishDeploy
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :allow_undeploy, :automatic_undeploy_minutes

    def initialize(config, allow_undeploy:, automatic_undeploy_minutes:)
      @config = config
      @allow_undeploy = allow_undeploy
      @automatic_undeploy_minutes = automatic_undeploy_minutes
    end

    def call
      asg = Asg.new(@config)

      puts ACTIVE_DEPLOY_MSG
      begin
        @config.assert_active
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        puts NOT_ACTIVE_MSG
        return { Status: :deploy_aborted }
      end
      puts ACTIVE_ASSERT_MSG

      deploy_asg = asg.get(@config.deploy_asg)
      puts "Allowing scale-in of new ASG #{deploy_asg.auto_scaling_group_name}"
      asg.set_min_size(deploy_asg)

      production_asg = @config.production_asg

      puts "Setting production asg #{deploy_asg.auto_scaling_group_name}"
      @config.set_production_asg(deploy_asg.auto_scaling_group_name, allow_undeploy: allow_undeploy)

      lt_version = deploy_asg.launch_template.version
      puts "Updating default launch template version to #{lt_version}"
      ec2 = Ec2.new(@config)
      ec2.set_default_launch_template_version(deploy_asg.launch_template.launch_template_id, lt_version)

      if production_asg
        production_asg = asg.get(production_asg)
      end

      # Previous config may be out of date -- this happens in dev when the dev environment gets torn down.
      if production_asg
        production_tg_arn = production_asg&.target_group_arns&.first

        puts "Destroying previous ASG #{production_asg.auto_scaling_group_name}"
        asg.destroy(production_asg.auto_scaling_group_name)

        if production_tg_arn
          elbv2 = ElbV2.new(@config)

          puts "Destroying previous target group #{production_tg_arn}"
          elbv2.destroy_tg(production_tg_arn)
        end
      end

      events = Events.new(@config)
      if automatic_undeploy_minutes
        time = Time.now.utc + (automatic_undeploy_minutes * 60)
        puts "Scheduling automatic undeploy for #{time}"
        events.schedule_undeploy(time)
      else
        events.disable_automatic_undeploy
      end

      puts "Deploy complete."
      { Status: :complete }
    end
  end
end
