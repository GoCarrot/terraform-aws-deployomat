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
  class Undeploy
    extend Forwardable

    DEFAULT_ON_CONCURRENT_DEPLOY = 'fail'

    def_delegators :@config, :account_name, :service_name, :prefix, :deploy_id, :params

    def initialize(config, undeploy_config:)
      undeploy_config = undeploy_config || {}
      @config = config

      @on_concurrent_deploy = undeploy_config.fetch('OnConcurrentDeploy', DEFAULT_ON_CONCURRENT_DEPLOY)
    end

    def call
      production_asg_name = @config.production_asg
      if production_asg_name.nil? || production_asg_name.empty?
        puts "No production ASG of #{service_name} in #{account_name} to undeploy, not deployed?"
        return { Status: :complete }
      end

      if !(@config.undeploying? || @config.undeployable?)
        error = "#{service_name} in #{account_name} cannot be undeployed. Do a new deploy with DeployConfig.AllowUndeploy set to true first."
        puts error
        return { Status: :fail, Error: [error] }
      end

      deploy_asg_name = @config.deploy_asg
      if deploy_asg_name && !deploy_asg_name.empty?
        puts "Deployment of #{service_name} in #{account_name} still in progress"
        return { Status: :deploy_active, OnConcurrentDeploy: @on_concurrent_deploy }
      end

      puts "Asserting start of undeploy"
      @config.assert_start_undeploy
      puts "Undeploy operation asserted"

      asg = Asg.new(@config)
      production_asg = asg.get(production_asg_name)

      elbv2 = ElbV2.new(@config)

      if !production_asg
        puts "Could not find production ASG #{production_asg_name}. Old entry?"
      end

      listeners = begin
        params.get_list_or_json("#{prefix}/config/#{service_name}/listener_arns")
      rescue Aws::SSM::Errors::ParameterNotFound
        puts "#{@service_name} is not a web service."
        nil
      end

      if production_asg
        puts "Destroying production ASG #{production_asg.auto_scaling_group_name}"
        asg.destroy(production_asg.auto_scaling_group_name)

        production_asg.target_group_arns&.each do |tg_arn|
          listeners&.each do |(key, listener_arn)|
            if !listener_arn
              listener_arn = key
              key = nil
            end

            rules = elbv2.find_rules_with_targets_in_listener(listener_arn, [tg_arn])
            rules.each do |rule|
              puts "Destroying rule in #{key} #{listener_arn} : #{rule.rule_arn}"
              elbv2.delete_rule(rule.rule_arn)
            end
          end

          puts "Destroying target group #{tg_arn}"
          elbv2.destroy_tg(tg_arn)
        end
      end

      @config.complete_undeploy
      events = Events.new(@config)
      events.disable_automatic_undeploy

      return { Status: :complete }
    end
  end
end
