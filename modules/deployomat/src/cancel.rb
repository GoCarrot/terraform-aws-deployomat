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
  class StartCancel
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    def initialize(config)
      @config = config
    end

    def call
      deploy_asg_name = @config.deploy_asg
      if deploy_asg_name.nil? || deploy_asg_name.empty?
        puts "No deployment of #{service_name} in #{account_name} active"
        return :fail
      end

      production_asg = @config.production_asg
      if production_asg.nil? || production_asg.empty?
        puts "No production ASG of #{service_name} in #{account_name} to failover to"
      end

      puts "Asserting start of cancel"
      @config.assert_start_cancel
      puts "Cancel operation asserted"

      asg = Asg.new(@config)
      deploy_asg = asg.get(deploy_asg_name)
      production_asg = asg.get(production_asg) if production_asg

      listeners = begin
        params.get_list_or_json("#{prefix}/config/#{service_name}/listener_arns")
      rescue Aws::SSM::Errors::ParameterNotFound
        puts "#{@service_name} is not a web service."
        nil
      end

      puts "Aborting deploy of #{deploy_asg_name}."
      if production_asg
        puts "Failing over to #{production_asg.auto_scaling_group_name}."
      else
        puts "Resetting to clean state."
      end

      if !listeners.nil?
       return reset_listeners(listeners, production_asg, deploy_asg)
      else
        return :success
      end
    end

  private

    def reset_listeners(listeners, production_asg, deploy_asg)
      elbv2 = ElbV2.new(@config)

      target_groups = [production_asg&.target_group_arns&.first, deploy_asg&.target_group_arns&.first].compact

      production_rules = listeners.flat_map do |(key, listener)|
        if !listener
          listener = key
          key = nil
        end

        puts "Identifying deploy rules for #{key} listener #{listener}"
        elbv2.find_rules_with_targets_in_listener(
          listener, target_groups
        )
      end.compact

      return :success if production_rules.empty?

      puts "Asserting active for web cancel"
      @config.assert_active
      puts "Asserted active"

      if production_asg
        puts "Coalescing on production asg #{production_asg.auto_scaling_group_name}"
        production_rules.each do |rule|
          if !elbv2.coalesce(rule, production_asg.target_group_arns.first)
            puts "Could not coalesece rule #{rule.rule_arn}. Destroying instead."
            elbv2.delete_rule(rule.rule_arn)
            puts "Destroyed #{rule.rule_arn}"
          end
        end
        puts "Coalesced."
        return :wait
      else
        puts "Destroying ALB rules"
        production_rules.each do |rule|
          elbv2.delete_rule(rule.rule_arn)
          puts "Destroyed #{rule.rule_arn}"
        end
        return :success
      end
    end
  end

  class FinishCancel
    extend Forwardable

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    def initialize(config)
      @config = config
    end

    def call
      puts "Asserting active cancel"
      @config.assert_active
      puts "Asserted active"

      deploy_asg_name = @config.deploy_asg
      if deploy_asg_name.nil? || deploy_asg_name.empty?
        msg = "No deployment of #{service_name} in #{account_name} active"
        puts msg
        return { Status: :fail, Error: msg }
      end

      production_asg = @config.production_asg
      if production_asg.nil? || production_asg.empty?
        puts "No production ASG of #{service_name} in #{account_name} to failover to"
      end

      asg = Asg.new(@config)

      deploy_asg = asg.get(deploy_asg_name)
      production_asg = asg.get(production_asg) if production_asg

      if deploy_asg
        puts "Destroying previous asg #{deploy_asg.auto_scaling_group_name}"
        asg.destroy(deploy_asg.auto_scaling_group_name)

        tg_arn = deploy_asg.target_group_arns&.first
        if !tg_arn.nil? && !tg_arn.empty?
          elbv2 = ElbV2.new(@config)

          puts "Destroying previous target group #{tg_arn}"
          elbv2.destroy_tg(tg_arn)
        end
      else
        puts "Notice: Deploy ASG was not provisioned. It is possible that there is a dangling unused target group."
        puts "This currently requires manual cleanup."
      end

      puts "Asserting active cancel before reenabling scale in"
      @config.assert_active
      puts "Asserted active."

      if production_asg
        puts "Restoring ASG scale in on #{production_asg.auto_scaling_group_name}"
        asg.set_min_size(production_asg)

        puts "Finalizing cancel."
        @config.set_production_asg(production_asg.auto_scaling_group_name)
      else
        puts "Resetting to clean state."
        @config.set_production_asg('')
      end

      return { Status: :complete }
    end
  end
end
