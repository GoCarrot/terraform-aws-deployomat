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

require 'aws-sdk-autoscaling'
require 'aws-sdk-dynamodb'
require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancingv2'
require 'aws-sdk-ssm'

module Deployomat
  MANAGED_TAG = ENV['DEPLOYOMAT_SERVICE_NAME']
  ORG_PREFIX = ENV['DEPLOYOMAT_ORG_PREFIX']

  class CredentialCache
    def self.meta_role_credentials(deploy_id)
      @meta_role_credentials ||= {}
      @meta_role_credentials[deploy_id] ||= begin
        Aws::AssumeRoleCredentials.new(
          role_arn: ENV['DEPLOYOMAT_META_ROLE_ARN'],
          role_session_name: deploy_id,
          tags: [
            {
              key: 'Environment',
              value: ENV['DEPLOYOMAT_ENV']
            }
          ],
          transitive_tag_keys: [
            'Environment'
          ]
        )
      end
    end

    def self.role_credentials(role_arn, deploy_id)
      @role_credentials ||= {}
      our_role_creds = @role_credentials[role_arn] ||= {}
      our_role_creds[deploy_id] ||= begin
        Aws::AssumeRoleCredentials.new(
          role_arn: role_arn,
          role_session_name: deploy_id
        )
      end
    end
  end

  class Parameters
    def initialize(deploy_id)
      @client = Aws::SSM::Client.new(
        credentials: CredentialCache.meta_role_credentials(deploy_id)
      )
    end

    def get(name)
      ret = @client.get_parameter(name: name)&.parameter
      if ret&.type == "StringList"
        ret.value.split(",").map(&:strip)
      else
        ret&.value
      end
    end
  end

  class Config
    attr_reader :account_name, :service_name, :prefix, :deploy_id, :params

    def initialize(account_name:, service_name:, deploy_id:, account_env: nil)
      @client = Aws::DynamoDB::Client.new
      @account_name = account_name
      @service_name = service_name
      @account_env = account_env || ENV['DEPLOYOMAT_ENV']
      @prefix = "/#{ENV['DEPLOYOMAT_ORG_PREFIX']}/#{@account_env}/#{@account_name}"
      @primary_key = "#{account_name}.#{service_name}"
      @deploy_id = deploy_id
      @params = Parameters.new(deploy_id)
      reload
    end

    def reload
      @config = @client.get_item(
        key: { 'id' => @primary_key },
        table_name: ENV['DEPLOYOMAT_TABLE'],
        consistent_read: true
      ).item
    end

    def production_asg
      @config&.fetch('production_asg_name', nil)
    end

    def deploy_asg
      @config&.fetch('deploy_asg_name', nil)
    end

    def assert_start_cancel
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: 'SET #DEPLOY_ID = :new_deploy_id',
        condition_expression: '#DEPLOY_ID = :old_deploy_id AND attribute_exists(#DEPLOY_ASG) AND #DEPLOY_ASG <> :empty',
        expression_attribute_names: {
          '#DEPLOY_ID' => 'deploy_id',
          '#DEPLOY_ASG' => 'deploy_asg_name'
        },
        expression_attribute_values: {
          ':new_deploy_id' => @deploy_id,
          ':old_deploy_id' => @config&.fetch('deploy_id', nil),
          ':empty' => ''
        }
      ).attributes
    end

    def assert_start_deploy(name)
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: 'SET #DEPLOY_ID = :new_deploy_id, #DEPLOY_ASG = :deploy_asg',
        condition_expression: '(attribute_not_exists(#DEPLOY_ID) OR #DEPLOY_ID = :old_deploy_id) AND (attribute_not_exists(#DEPLOY_ASG) OR #DEPLOY_ASG = :empty)',
        expression_attribute_names: {
          '#DEPLOY_ID' => 'deploy_id',
          '#DEPLOY_ASG' => 'deploy_asg_name'
        },
        expression_attribute_values: {
          ':new_deploy_id' => @deploy_id,
          ':old_deploy_id' => @config&.fetch('deploy_id', nil),
          ':empty' => '',
          ':deploy_asg' => name
        }
      ).attributes
    end

    def assert_active
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: 'SET #DEPLOY_ID = :deploy_id',
        condition_expression: '#DEPLOY_ID = :deploy_id',
        expression_attribute_names: {
          '#DEPLOY_ID' => 'deploy_id'
        },
        expression_attribute_values: {
          ':deploy_id' => @deploy_id
        }
      ).attributes
    end

    def set_production_asg(name)
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: 'SET #PROD_ASG = :prod_asg, #DEPLOY_ASG = :empty',
        condition_expression: '#DEPLOY_ID = :deploy_id',
        expression_attribute_names: {
          '#DEPLOY_ID' => 'deploy_id',
          '#PROD_ASG' => 'production_asg_name',
          '#DEPLOY_ASG' => 'deploy_asg_name'
        },
        expression_attribute_values: {
          ':deploy_id' => @deploy_id,
          ':prod_asg' => name,
          ':empty' => ''
        }
      ).attributes
    end
  end

  class Ec2
    def initialize(role_arn, deploy_id)
      @client = Aws::EC2::Client.new(
        credentials: CredentialCache.role_credentials(role_arn, deploy_id)
      )
    end

    def create_launch_template_version(launch_template_id, ami_id)
      @client.create_launch_template_version(
        launch_template_data: {
          image_id: ami_id
        },
        launch_template_id: launch_template_id,
        source_version: "$Latest"
      ).launch_template_version
    end
  end

  class Asg
    REMOVE_HOOK_PARAMS = %i[global_timeout auto_scaling_group_name].freeze
    REMOVE_TAG_PARAMS = %i[resource_id resource_type].freeze
    REMOVE_POLICY_PARAMS = %i[policy_arn alarms].freeze
    DEFAULT_MAX_SIZE = 4

    def initialize(role_arn, deploy_id)
      @client = Aws::AutoScaling::Client.new(
        credentials: CredentialCache.role_credentials(role_arn, deploy_id)
      )
    end

    def get(name)
      @client.describe_auto_scaling_groups(
        auto_scaling_group_names: [name]
      ).auto_scaling_groups.first
    end

    def destroy(name)
      @client.delete_auto_scaling_group(
        auto_scaling_group_name: name,
        force_delete: true
      )
    end

    def set_min_size(asg)
      min_size = asg.min_size
      asg.tags.each do |tag|
        tag = tag.to_h
        min_size = tag[:value].to_i if tag[:key] == "#{ORG_PREFIX}:min_size"
      end

      @client.update_auto_scaling_group(
        auto_scaling_group_name: asg.auto_scaling_group_name,
        min_size: min_size
      )
    end

    # Rather than using any of the AWS default ways of preventing scale in, we
    # set the minimum size of the ASG to its current size. This allows the ASG
    # to continue performing regular operations such as replacing unhealthy
    # instances and rebalancing across AZs while preventing it from reducing
    # capacity during deployment.
    #
    # We prevent ASGs from reducing capacity during deployments so that if a
    # deployment is aborted we can immediately fail back to the original ASG
    # without risking a scenario where the ASG has scaled in and can no longer
    # handle the full production traffic load.
    def prevent_scale_in(asg)
      @client.update_auto_scaling_group(
        auto_scaling_group_name: asg.auto_scaling_group_name,
        min_size: [asg.instances.length, asg.min_size].max
      )
    end

    def clone_asg(template_asg, launch_template, name, min_size, target_group_arn)
      hooks = @client.describe_lifecycle_hooks(
        auto_scaling_group_name: template_asg.auto_scaling_group_name
      ).lifecycle_hooks.map(&:to_h)

      hooks.each do |hook|
        REMOVE_HOOK_PARAMS.each { |param| hook.delete(param) }
      end

      tags = template_asg.tags.map(&:to_h)
      default_min_size = max_size = nil
      tags.each do |tag|
        REMOVE_TAG_PARAMS.each { |param| tag.delete(param) }

        max_size = tag[:value].to_i if tag[:key] == "#{ORG_PREFIX}:max_size"
        default_min_size = tag[:value].to_i if tag[:key] == "#{ORG_PREFIX}:min_size"
      end

      managed = tags.find { |tag| tag[:key] == 'Managed' }
      if managed
        managed[:value] = MANAGED_TAG
      else
        tags.push({ key: 'Managed', value: MANAGED_TAG })
      end

      new_asg_parameters = {
        auto_scaling_group_name: name,
        launch_template: {
          launch_template_id: launch_template.launch_template_id,
          version: launch_template.version_number.to_s
        },
        vpc_zone_identifier: template_asg.vpc_zone_identifier,
        service_linked_role_arn: template_asg.service_linked_role_arn,
        lifecycle_hook_specification_list: hooks,
        health_check_type: template_asg.health_check_type,
        health_check_grace_period: template_asg.health_check_grace_period,
        max_instance_lifetime: template_asg.max_instance_lifetime,
        termination_policies: template_asg.termination_policies,
        tags: tags,
        desired_capacity_type: template_asg.desired_capacity_type,
        max_size: max_size || DEFAULT_MAX_SIZE,
        min_size: [min_size.to_i, default_min_size.to_i].max,
      }

      if target_group_arn
        new_asg_parameters[:target_group_arns] = [target_group_arn]
      end

      @client.create_auto_scaling_group(new_asg_parameters)

      if template_asg.warm_pool_configuration
        @client.put_warm_pool(
          auto_scaling_group_name: name,
          pool_state: template_asg.warm_pool_configuration.pool_state,
        )
      end

      scaling_policies = @client.describe_policies(
        auto_scaling_group_name: template_asg.auto_scaling_group_name
      ).scaling_policies

      scaling_policies.each do |policy|
        policy = policy.to_h
        REMOVE_POLICY_PARAMS.each { |param| policy.delete(param) }

        policy.delete(:step_adjustments) if policy[:policy_type] == 'TargetTrackingScaling'

        policy = policy.merge(auto_scaling_group_name: name)
        @client.put_scaling_policy(policy)
      end
    end
  end

  class ElbV2
    REMOVE_TG_PARAMS = %i[target_group_arn target_group_name load_balancer_arns].freeze
    REMOVE_RULE_PARAMS = %i[rule_arn is_default].freeze
    REMOVE_MODIFY_RULE_PARAMS = %i[is_default priority].freeze
    PRIORITY_OFFSET = 40_000

    def initialize(role_arn, deploy_id)
      @client = Aws::ElasticLoadBalancingV2::Client.new(
        credentials: CredentialCache.role_credentials(role_arn, deploy_id)
      )
    end

    def clone_target_group(target_group_arn, clone_name)
      new_tg_conf = @client.describe_target_groups(target_group_arns: [target_group_arn]).target_groups&.first&.to_h
      REMOVE_TG_PARAMS.each { |param| new_tg_conf.delete(param) }
      tags = @client.describe_tags(resource_arns: [target_group_arn]).tag_descriptions&.first&.tags

      managed = tags.find { |tag| tag[:key] == 'Managed' }
      if managed
        managed[:value] = MANAGED_TAG
      else
        tags.push({ key: 'Managed', value: MANAGED_TAG })
      end

      new_tg_conf[:tags] = tags
      @client.create_target_group(
        new_tg_conf.merge(name: clone_name)
      ).target_groups.first
    end

    def find_rule_with_target_in_listener(listener_arn, target_group)
      rules = @client.describe_rules(listener_arn: listener_arn).rules
      production_rule = exemplar_rule = nil

      # TODO: Support multiple rules per target group.
      rules.find do |rule|
        rule.actions.any? { |action| action.forward_config&.target_groups&.any? { |tg_conf| tg_conf.target_group_arn == target_group } }
      end
    end

    def prepare_deploy_rule(listener_arn, production_tg_arn, exemplar_tg_arn, deploy_tg_arn)
      rules = @client.describe_rules(listener_arn: listener_arn).rules
      production_rule = exemplar_rule = nil

      # TODO: Support multiple rules per target group.
      rules.each do |rule|
        if rule.actions.any? { |action| action.forward_config&.target_groups&.any? { |tg_conf| tg_conf.target_group_arn == exemplar_tg_arn } }
          exemplar_rule = rule
        elsif rule.actions.any? { |action| action.forward_config && action.forward_config.target_groups.any? { |tg_conf| tg_conf.target_group_arn == production_tg_arn } }
          production_rule = rule
        end
      end

      if !production_rule && exemplar_rule
        tags = @client.describe_tags(resource_arns: [exemplar_rule.rule_arn]).tag_descriptions&.first&.tags

        managed = tags.find { |tag| tag[:key] == 'Managed' }
        if managed
          managed[:value] = MANAGED_TAG
        else
          tags.push({ key: 'Managed', value: MANAGED_TAG })
        end
        # Assert exemplar priority >= 40k
        new_rule = exemplar_rule.to_h
        new_rule[:priority] = (new_rule[:priority].to_i - PRIORITY_OFFSET).to_s
        new_rule[:actions].each do |action|
          if action[:target_group_arn] == exemplar_tg_arn
            action[:target_group_arn] = deploy_tg_arn
          end

          if action[:forward_config]
            action[:forward_config][:target_groups].each do |group|
              group[:target_group_arn] = deploy_tg_arn if group[:target_group_arn] == exemplar_tg_arn
            end
          end
        end
        new_rule[:conditions].each do |condition|
          condition.delete(:values)
        end
        new_rule[:listener_arn] = listener_arn
        new_rule[:tags] = tags
        REMOVE_RULE_PARAMS.each { |param| new_rule.delete(param) }

        # TODO: This can fail if another deployomat creates a rule before us. We should
        # clean up all resources and terminate in that case.
        [:initial, @client.create_rule(new_rule).rules.first]
      else
        new_rule = production_rule.to_h
        action = new_rule[:actions].find { |action| action.dig(:forward_config, :target_groups)&.any? { |tg_conf| tg_conf[:target_group_arn] == production_tg_arn } }
        action.delete(:target_group_arn)

        # TODO: Assert that the production rule only contains one forward to the known production tg.

        action[:forward_config][:target_groups] = [
          {
            target_group_arn: production_tg_arn,
            weight: 100
          },
          {
            target_group_arn: deploy_tg_arn,
            weight: 0
          }
        ]

        [:update,  modify_rule(new_rule)]
      end
    end

    def shift_traffic(rule, amount, production_tg_arn, deploy_tg_arn)
      new_rule = rule.to_h
      forwards = new_rule[:actions].find { |action| action.dig(:forward_config, :target_groups)&.any? { |tg_conf| tg_conf[:target_group_arn] == production_tg_arn } }.dig(:forward_config, :target_groups)
      production_forward = forwards.find { |tg_conf| tg_conf[:target_group_arn] == production_tg_arn }
      deploy_forward = forwards.find { |tg_conf| tg_conf[:target_group_arn] == deploy_tg_arn }

      # TODO: Assert forwards.length == 2, production_forward exists, deploy_forward exists
      # TODO: clamp weights to [0, 100]
      production_forward[:weight] -= amount
      deploy_forward[:weight] += amount

      modify_rule(new_rule)
    end

    def coalesce(rule, production_tg_arn)
      new_rule = rule.to_h
      forwards = new_rule[:actions].find { |action| action.dig(:forward_config, :target_groups)&.any? { |tg_conf| tg_conf[:target_group_arn] == production_tg_arn } }.dig(:forward_config)
      forwards[:target_groups] = [{ target_group_arn: production_tg_arn, weight: 100 }]

      modify_rule(new_rule)
    end

    def destroy_tg(target_group_arn)
      @client.delete_target_group(target_group_arn: target_group_arn)
    end

    def count_healthy(target_group_arn)
      @client.describe_target_health(target_group_arn: target_group_arn).target_health_descriptions.count { |thd| thd.target_health.state == "healthy" }
    end

    def describe_rules(rule_arns)
      @client.describe_rules(rule_arns: rule_arns).rules
    end

  private

    def modify_rule(new_rule)
      REMOVE_MODIFY_RULE_PARAMS.each { |param| new_rule.delete(param) }
      new_rule[:conditions].each do |condition|
        condition.delete(:values)
      end
      @client.modify_rule(new_rule).rules.first
    end
  end
end
