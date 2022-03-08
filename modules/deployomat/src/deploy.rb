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

module Deployomat
  class StartDeploy
    extend Forwardable

    DEFAULT_BAKE_TIME = 30
    DEFAULT_TRAFFIC_SHIFT_PER_STEP = 5
    DEFAULT_WAIT_PER_STEP = 15
    DEFAULT_HEALTH_TIMEOUT = 300
    DEFAULT_ON_CONCURRENT_DEPLOY = 'rollback'

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    attr_reader :ami_id, :new_asg_name, :bake_time, :health_timeout, :traffic_shift_per_step, :wait_per_step

    GREATER_THAN_ZERO = %i[bake_time traffic_shift_per_step wait_per_step health_timeout].freeze

    def initialize(config, ami_id:, deploy_config:)
      deploy_config = deploy_config || {}
      @config = config
      @ami_id = ami_id
      @new_asg_name = "#{service_name}-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"

      # TODO: These should be configurable.
      @bake_time = deploy_config.fetch('BakeTime', DEFAULT_BAKE_TIME)
      @traffic_shift_per_step = deploy_config.fetch('TrafficShiftPerStep', DEFAULT_TRAFFIC_SHIFT_PER_STEP)
      @wait_per_step = deploy_config.fetch('WaitPerStep', DEFAULT_WAIT_PER_STEP)
      @health_timeout = deploy_config.fetch('HealthTimeout', DEFAULT_HEALTH_TIMEOUT)
      @on_concurrent_deploy = deploy_config.fetch('OnConcurrentDeploy', DEFAULT_ON_CONCURRENT_DEPLOY)
    end

    def call
      error = false
      if ami_id.nil? || ami_id.empty?
        puts "No AMI specified"
        error = true
      end

      GREATER_THAN_ZERO.each do |check_attr|
        if send(check_attr) < 0
          puts "#{check_attr} must be greater than zero"
          error = true
        end
      end

      if error
        puts "Failing due to invalid configuration."
        return { Status: :fail }
      end

      asg = Asg.new(@config)

      template_asg_name = "#{service_name}-template"
      puts "Fetching template asg..."
      template_asg = asg.get(template_asg_name)

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
        else
          return { Status: :fail }
        end
      end

      ec2 = Ec2.new(@config)
      puts "Creating launch template version..."
      lt = ec2.create_launch_template_version(template_asg.launch_template.launch_template_id, ami_id)
      puts "Created launch template version #{lt.version_number}"

      elbv2 = ElbV2.new(@config)
      # TODO: Support multiple target groups per asg.
      exemplar_tg_arn = template_asg.target_group_arns&.first
      new_target_group = nil
      new_target_group_arn = nil
      if exemplar_tg_arn
        puts "Cloning target group..."
        new_target_group = elbv2.clone_target_group(exemplar_tg_arn, new_asg_name)
        new_target_group_arn = new_target_group.target_group_arn
        puts "Cloned target group #{new_target_group_arn}"
      end

      puts "Cloning asg..."
      asg.clone_asg(template_asg, lt, new_asg_name, production_asg&.instances&.length, new_target_group_arn)

      if production_asg
        puts "Asserting active deploy"
        begin
          @config.assert_active
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          puts "No longer active deploy."
          return { Status: :fail }
        end
        puts "Asserted active"
        puts "Preventing scale-in of #{production_asg.auto_scaling_group_name}"
        asg.prevent_scale_in(production_asg)
      end

      production_tg_arn = production_asg&.target_group_arns&.first

      if exemplar_tg_arn
        production_rules = []
        listeners = params.get("#{prefix}/config/#{service_name}/listener_arns")
        listeners.each do |listener|
          puts "Preparing deploy rule for listener #{listener}..."
          production_rules << elbv2.prepare_deploy_rule(
            listener, production_tg_arn, exemplar_tg_arn, new_target_group_arn
          )
        end

        if production_rules.all? { |rule| rule.first == :initial }
          return {
            Status: :success, WaitForBakeTime: bake_time, RuleIds: production_rules.map { |pr| pr[1].rule_arn },
            NewTargetGroupArn: new_target_group_arn
          }
        end

        production_rules.map! { |pr| pr[1].rule_arn }

        deploy_asg = asg.get(new_asg_name)
        requested_min = deploy_asg.min_size

        return {
          Status: :wait_healthy, WaitForHealthyTime: health_timeout, NewTargetGroupArn: new_target_group_arn,
          OldTargetGroupArn: production_tg_arn, MinHealthy: requested_min, TrafficShiftPerStep: traffic_shift_per_step,
          WaitPerStep: wait_per_step, RuleIds: production_rules, WaitForBakeTime: bake_time
        }
      else
        return { Status: :success, WaitForBakeTime: bake_time, RuleIds: '', NewTargetGroupArn: '' }
      end
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

      puts "Asserting active deploy"
      begin
        @config.assert_active
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        puts "No longer active deploy."
        return { Status: :deploy_aborted }
      end
      puts "Asserted active"

      healthy_count = elbv2.count_healthy(target_group_arn)
      puts "Waiting for #{min_healthy} healthy instances, have #{healthy_count}"

      if min_healthy == healthy_count
        { Status: :complete }
      elsif remaining_time >= seconds_to_wait
        { Status: :wait, Wait: seconds_to_wait, RemainingTime: remaining_time - seconds_to_wait }
      else
        { Status: :fail }
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
        puts "Asserting active deploy"
        begin
          @config.assert_active
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          puts "No longer active deploy."
          return { Status: :deploy_aborted }
        end
        puts "Asserted active"
        elbv2.shift_traffic(rule, step_size, old_target_group_arn, target_group_arn)
        puts "Shifted traffic on #{rule.rule_arn} to #{total}%"
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
        puts "Asserting active deploy"
        begin
          @config.assert_active
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          puts "No longer active deploy."
          return { Status: :deploy_aborted }
        end
        puts "Asserted active"
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

    def initialize(config)
      @config = config
    end

    def call
      asg = Asg.new(@config)

      puts "Asserting active deploy"
      begin
        @config.assert_active
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        puts "No longer active deploy."
        return { Status: :deploy_aborted }
      end
      puts "Asserted active"

      deploy_asg = asg.get(@config.deploy_asg)
      puts "Allowing scale-in of new ASG #{deploy_asg.auto_scaling_group_name}"
      asg.set_min_size(deploy_asg)

      production_asg = @config.production_asg

      puts "Setting production asg #{deploy_asg.auto_scaling_group_name}"
      @config.set_production_asg(deploy_asg.auto_scaling_group_name)

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

      puts "Deploy complete."
      { Status: :complete }
    end
  end
end
