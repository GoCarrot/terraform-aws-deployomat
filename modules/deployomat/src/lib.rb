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
require 'aws-sdk-eventbridge'
require 'aws-sdk-ssm'

require 'json'

module Deployomat
  MANAGED_TAG = ENV['DEPLOYOMAT_SERVICE_NAME']
  DEPLOY_ROLE_NAME = ENV['DEPLOYOMAT_SERVICE_NAME']

  class CredentialCache
    def self.meta_role_credentials(deploy_id)
      @meta_role_credentials ||= {}
      @meta_role_credentials[deploy_id] ||= begin
        Aws::AssumeRoleCredentials.new(
          role_arn: ENV['DEPLOYOMAT_META_ROLE_ARN'],
          role_session_name: deploy_id[0...64],
          external_id: ENV['ROLE_EXTERNAL_ID'],
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
          role_session_name: deploy_id[0...64],
          external_id: ENV['ROLE_EXTERNAL_ID']
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

    def get_list_or_json(name)
      ret = @client.get_parameter(name: name)&.parameter
      if ret&.type == "StringList"
        ret.value.split(",").map(&:strip)
      else
        JSON.parse(ret&.value)
      end
    end
  end

  class Config
    UNDEPLOYING = 'undeploying'
    ALLOW = 'allow'

    ID_VAR = '#DEPLOY_ID'
    ASG_VAR = '#DEPLOY_ASG'
    UNDEPLOY_VAR = '#UNDEPLOY_STATE'
    PROD_ASG_VAR = '#PROD_ASG'

    ID_KEY = ':deploy_id'
    ASG_KEY = ':deploy_asg'
    NEW_ID_KEY = ':new_deploy_id'
    OLD_ID_KEY = ':old_deploy_id'
    EMPTY_KEY = ':empty'
    UNDEPLOY_KEY = ':undeploying'
    ALLOW_KEY = ':allow'
    PROD_ASG_KEY = ':prod_asg'
    UNDEPLOY_STATE_KEY = ':undeploy_state'

    ID_NAME = 'deploy_id'
    ASG_NAME = 'deploy_asg_name'
    UNDEPLOY_STATE_NAME = 'undeploy_state'
    DEPLOY_NAME = 'deploy_asg'
    PROD_ASG_NAME = 'production_asg_name'

    attr_reader :account_canonical_slug, :account_name, :service_name, :prefix,
                :deploy_id, :params, :organization_prefix, :account_environment,
                :primary_key

    def initialize(account_canonical_slug:, service_name:, deploy_id:)
      @client = Aws::DynamoDB::Client.new
      @account_canonical_slug = account_canonical_slug
      @service_name = service_name
      @params = Parameters.new(deploy_id)
      account_info = begin
        JSON.parse(params.get("/omat/account_registry/#{@account_canonical_slug}"), symbolize_names: true)
      rescue Aws::SSM::ParameterNotFound
        raise "Unable to locate account information for #{@account_canonical_slug}"
      end

      @prefix = account_info[:prefix]
      @organization_prefix = @prefix.split('/').reject(&:empty?)[0]
      @account_name = account_info[:name]
      @account_environment = account_info[:environment]
      @primary_key = "#{account_canonical_slug}.#{service_name}"
      @deploy_id = deploy_id

      reload
    end

    def deploy_role_arn
      @deploy_role_arn ||= params.get("#{prefix}/roles/#{DEPLOY_ROLE_NAME}")
    end

    def reload
      @config = @client.get_item(
        key: { 'id' => @primary_key },
        table_name: ENV['DEPLOYOMAT_TABLE'],
        consistent_read: true
      ).item
    end

    def production_asg
      @config&.fetch(PROD_ASG_NAME, nil)
    end

    def deploy_asg
      @config&.fetch(ASG_NAME, nil)
    end

    def undeploying?
      @config&.fetch(UNDEPLOY_STATE_NAME, '') == UNDEPLOYING
    end

    def undeployable?
      @config&.fetch(UNDEPLOY_STATE_NAME, '') == ALLOW
    end

    ASSERT_START_CANCEL_UPDATE_EXPR = "SET #{ID_VAR} = #{NEW_ID_KEY}"
    ASSERT_START_CANCEL_CONDITION_EXPR = "#{ID_VAR} = #{OLD_ID_KEY} AND attribute_exists(#{ASG_VAR}) AND #{ASG_VAR} <> #{EMPTY_KEY}"

    def assert_start_cancel
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: ASSERT_START_CANCEL_UPDATE_EXPR,
        condition_expression: ASSERT_START_CANCEL_CONDITION_EXPR,
        expression_attribute_names: {
          ID_VAR => ID_NAME,
          ASG_VAR => ASG_NAME
        },
        expression_attribute_values: {
          NEW_ID_KEY => @deploy_id,
          OLD_ID_KEY => @config&.fetch(ID_NAME, nil),
          EMPTY_KEY => ''
        }
      ).attributes
    end

    ASSERT_START_DEPLOY_UPDATE_EXPR = "SET #{ID_VAR} = #{NEW_ID_KEY}, #{ASG_VAR} = #{ASG_KEY}"
    ASSERT_START_DEPLOY_CONDITION_EXPR = "(attribute_not_exists(#{ID_VAR}) OR #{ID_VAR} = #{OLD_ID_KEY}) AND (attribute_not_exists(#{ASG_VAR}) OR #{ASG_VAR} = #{EMPTY_KEY}) AND (attribute_not_exists(#{UNDEPLOY_VAR}) OR #{UNDEPLOY_VAR} <> #{UNDEPLOY_KEY})"

    def assert_start_deploy(name)
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: ASSERT_START_DEPLOY_UPDATE_EXPR,
        condition_expression: ASSERT_START_DEPLOY_CONDITION_EXPR,
        expression_attribute_names: {
          ID_VAR => ID_NAME,
          ASG_VAR => ASG_NAME,
          UNDEPLOY_VAR => UNDEPLOY_STATE_NAME
        },
        expression_attribute_values: {
          NEW_ID_KEY => @deploy_id,
          OLD_ID_KEY => @config&.fetch(ID_NAME, nil),
          EMPTY_KEY => '',
          ASG_KEY => name,
          UNDEPLOY_KEY => UNDEPLOYING
        }
      ).attributes
    end

    ASSERT_START_UNDEPLOY_UPDATE_EXPR = "SET #{ID_VAR} = #{NEW_ID_KEY}, #{UNDEPLOY_VAR} = #{UNDEPLOY_KEY}"
    ASSERT_START_UNDEPLOY_CONDITION_EXPR = "(attribute_not_exists(#{ID_VAR}) OR #{ID_VAR} = #{OLD_ID_KEY}) AND (attribute_not_exists(#{ASG_VAR}) OR #{ASG_VAR} = #{EMPTY_KEY}) AND (#{UNDEPLOY_VAR} = #{ALLOW_KEY} OR #{UNDEPLOY_VAR} = #{UNDEPLOY_KEY})"

    def assert_start_undeploy
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: ASSERT_START_UNDEPLOY_UPDATE_EXPR,
        condition_expression: ASSERT_START_UNDEPLOY_CONDITION_EXPR,
        expression_attribute_names: {
          ID_VAR => ID_NAME,
          ASG_VAR => DEPLOY_NAME,
          UNDEPLOY_VAR => UNDEPLOY_STATE_NAME
        },
        expression_attribute_values: {
          NEW_ID_KEY => @deploy_id,
          OLD_ID_KEY => @config&.fetch(ID_NAME, nil),
          EMPTY_KEY => '',
          UNDEPLOY_KEY => UNDEPLOYING,
          ALLOW_KEY => ALLOW
        }
      ).attributes
    end

    COMPLETE_UNDEPLOY_CONDITION_EXPR = "(attribute_not_exists(#{ID_VAR}) OR #{ID_VAR} = #{ID_KEY}) AND (attribute_not_exists(#{UNDEPLOY_VAR}) OR #{UNDEPLOY_VAR} = #{UNDEPLOY_KEY})"

    def complete_undeploy
      @config = @client.delete_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_OLD',
        key: { 'id' => @primary_key },
        condition_expression: COMPLETE_UNDEPLOY_CONDITION_EXPR,
        expression_attribute_names: {
          ID_VAR => ID_NAME,
          UNDEPLOY_VAR => UNDEPLOY_STATE_NAME
        },
        expression_attribute_values: {
          ID_KEY => @deploy_id,
          UNDEPLOY_KEY => UNDEPLOYING
        }
      )
    end

    ASSERT_ACTIVE_UPDATE_EXPR = "SET #{ID_VAR} = #{ID_KEY}"
    ASSERT_ACTIVE_CONDITION_EXPR = "#{ID_VAR} = #{ID_KEY}"

    def assert_active
      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: ASSERT_ACTIVE_UPDATE_EXPR,
        condition_expression: ASSERT_ACTIVE_CONDITION_EXPR,
        expression_attribute_names: {
          ID_VAR => ID_NAME
        },
        expression_attribute_values: {
          ID_KEY => @deploy_id
        }
      ).attributes
    end

    SET_PROD_ASG_UPDATE_EXPR = "SET #{PROD_ASG_VAR} = #{PROD_ASG_KEY}, #{ASG_VAR} = #{EMPTY_KEY}, #{UNDEPLOY_VAR} = #{UNDEPLOY_STATE_KEY}"
    SET_PROD_ASG_CONDITION_EXPR = "#{ID_VAR} = #{ID_KEY}"

    def set_production_asg(name, allow_undeploy: nil)
      allow_undeploy = undeploying? || undeployable? if allow_undeploy.nil?

      @config = @client.update_item(
        table_name: ENV['DEPLOYOMAT_TABLE'],
        return_values: 'ALL_NEW',
        key: { 'id' => @primary_key },
        update_expression: SET_PROD_ASG_UPDATE_EXPR,
        condition_expression: SET_PROD_ASG_CONDITION_EXPR,
        expression_attribute_names: {
          ID_VAR => ID_NAME,
          PROD_ASG_VAR => PROD_ASG_NAME,
          ASG_VAR => ASG_NAME,
          UNDEPLOY_VAR => UNDEPLOY_STATE_NAME
        },
        expression_attribute_values: {
          ID_KEY => @deploy_id,
          PROD_ASG_KEY => name,
          EMPTY_KEY => '',
          UNDEPLOY_STATE_KEY => allow_undeploy ? ALLOW : ''
        }
      ).attributes
    end
  end

  class Ec2
    def initialize(config)
      @client = Aws::EC2::Client.new(
        credentials: CredentialCache.role_credentials(config.deploy_role_arn, config.deploy_id)
      )
    end

    def launch_template_version(launch_template_id, version, offset)
      if version != '$LatestMinus'
        @client.describe_launch_template_versions(
          launch_template_id: launch_template_id,
          versions: [version]
        ).launch_template_versions.first
      else
        latest_version = @client.describe_launch_template_versions(
          launch_template_id: launch_template_id,
          versions: ['$Latest']
        ).launch_template_versions.first.version_number
        version = (latest_version.to_i - offset.to_i).to_s
        launch_template_version(launch_template_id, version, nil)
      end
    end

    def latest_ami_for_name_prefix(name_prefix)
      owners = ENV['DEPLOYOMAT_AMI_SEARCH_OWNERS']&.split(',')
      if !owners || owners.empty?
        raise "Must specify AWS account ids which can build AMIs in DEPLOYOMAT_AMI_SEARCH_OWNERS"
      end

      images = @client.describe_images(
        executable_users: ['self'],
        filters: [
          {
            name: 'state',
            values: ['available']
          }
        ],
        owners: owners
      ).images
      images.select! { |img| img.name.start_with?(name_prefix) }
      images.sort_by! { |img| img.creation_date }.last
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

    def set_default_launch_template_version(launch_template_id, version)
      @client.modify_launch_template(
        launch_template_id: launch_template_id,
        default_version: version.to_s
      ).launch_template.default_version_number
    end
  end

  class Events
    TARGET_NAME = 'RunUndeploy'

    def initialize(config)
      @config = config
      @client = Aws::EventBridge::Client.new
    end

    def schedule_undeploy(time)
      cron_expression = "cron(#{time.min} #{time.hour} #{time.day} #{time.month} ? #{time.year})"
      undeploy_desc = "automatic undeploy of #{@config.service_name} in #{@config.account_canonical_slug}"
      rule = @client.put_rule(
        name: rule_name,
        schedule_expression: cron_expression,
        state: 'ENABLED',
        description: "Trigger for #{undeploy_desc}",
        tags: [
          {
            key: 'Environment',
            value: ENV['DEPLOYOMAT_ENV']
          },
          {
            key: 'Managed',
            value: MANAGED_TAG
          },
          {
            key: 'CostCenter',
            value: MANAGED_TAG
          },
          {
            key: 'Service',
            value: @config.service_name
          }
        ]
      )

      @client.put_targets(
        rule: rule_name,
        targets: [
          {
            id: TARGET_NAME,
            arn: ENV['UNDEPLOY_SFN_ARN'],
            role_arn: ENV['UNDEPLOYER_ROLE_ARN'],
            input: JSON.generate({
              Comment: undeploy_desc,
              ServiceName: @config.service_name,
              AccountCanonicalSlug: @config.account_canonical_slug,
              UndeployConfig: {
                OnConcurrentDeploy: 'fail'
              }
            })
          }
        ]
      )
    end

    def disable_automatic_undeploy
      begin
        @client.describe_rule(name: rule_name)
        @client.remove_targets(
          rule: rule_name,
          ids: [TARGET_NAME]
        )
        @client.delete_rule(name: rule_name)
      rescue Aws::EventBridge::Errors::ResourceNotFoundException
        # This is fine, just means we've never scheduled an automatic undeploy.
      end
    end

  private
    def rule_name
      @rule_name ||= "#{@config.primary_key[0...54]}-undeploy"
    end
  end


  class Asg
    REMOVE_HOOK_PARAMS = %i[global_timeout auto_scaling_group_name].freeze
    REMOVE_TAG_PARAMS = %i[resource_id resource_type].freeze
    REMOVE_POLICY_PARAMS = %i[policy_arn alarms].freeze
    DEFAULT_MAX_SIZE = 4

    def initialize(config)
      @org_prefix = config.organization_prefix
      @client = Aws::AutoScaling::Client.new(
        credentials: CredentialCache.role_credentials(config.deploy_role_arn, config.deploy_id)
      )
    end

    def get(name)
      return nil if name.nil? || name.empty?

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
        min_size = tag[:value].to_i if tag[:key] == "#{@org_prefix}:min_size"
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
        min_size: [[asg.instances.length, asg.min_size].max, asg.max_size].min
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

        max_size = tag[:value].to_i if tag[:key] == "#{@org_prefix}:max_size"
        default_min_size = tag[:value].to_i if tag[:key] == "#{@org_prefix}:min_size"
      end

      managed = tags.find { |tag| tag[:key] == 'Managed' }
      if managed
        managed[:value] = MANAGED_TAG
      else
        tags.push({ key: 'Managed', value: MANAGED_TAG })
      end

      max_size = max_size || DEFAULT_MAX_SIZE

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
        max_size: max_size,
        min_size: [[min_size.to_i, default_min_size.to_i].max, max_size].min
      }

      if target_group_arn
        new_asg_parameters[:target_group_arns] = [target_group_arn]
      end

      if template_asg.placement_group
        new_asg_parameters[:placement_group] = template_asg.placement_group
      end

      retry_count = 0
      begin
        @client.create_auto_scaling_group(new_asg_parameters)
      rescue Aws::AutoScaling::Errors::AlreadyExistsFault
        # If we got here and never retried, we are in trouble
        # If we got here because a retry succeeded, we're okay.
        raise if retry_count == 0
      # The most common reason we get here is an eventual consistency issue with target groups.
      # We see from time to time that AutoScaling isn't able to identify a target group that was
      # recently created.
      rescue Aws::AutoScaling::Errors::ServiceError => exc
        puts "Error cloning ASG to #{name}. #{exc.class.name} #{exc.message}"
        retry_count += 1
        raise if retry_count >= 3
        puts "Retrying #{retry_count}"
        sleep 2 ** retry_count
        retry
      end

      if template_asg.enabled_metrics && template_asg.enabled_metrics.length > 0
        @client.enable_metrics_collection(
          auto_scaling_group_name: name,
          granularity: template_asg.enabled_metrics[0].granularity,
          metrics: template_asg.enabled_metrics.map(&:metric)
        )
      end

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

    def initialize(config)
      @client = Aws::ElasticLoadBalancingV2::Client.new(
        credentials: CredentialCache.role_credentials(config.deploy_role_arn, config.deploy_id)
      )
    end

    def clone_target_group(target_group_arn, clone_name)
      new_tg_conf = @client.describe_target_groups(target_group_arns: [target_group_arn]).target_groups&.first&.to_h
      new_tg_attributes = @client.describe_target_group_attributes(target_group_arn: target_group_arn).attributes
      REMOVE_TG_PARAMS.each { |param| new_tg_conf.delete(param) }
      tags = @client.describe_tags(resource_arns: [target_group_arn]).tag_descriptions&.first&.tags

      managed = tags.find { |tag| tag[:key] == 'Managed' }
      if managed
        managed[:value] = MANAGED_TAG
      else
        tags.push({ key: 'Managed', value: MANAGED_TAG })
      end

      new_tg_conf[:tags] = tags
      new_tg = @client.create_target_group(
        new_tg_conf.merge(name: clone_name.gsub(/[^A-Za-z0-9\-]/, '-')[0...32])
      ).target_groups.first
      @client.modify_target_group_attributes(target_group_arn: new_tg.target_group_arn, attributes: new_tg_attributes)
      return new_tg
    end

    def find_rules_with_targets_in_listener(listener_arn, target_groups)
      rules = @client.describe_rules(listener_arn: listener_arn).rules

      rules.select do |rule|
        rule.actions.any? { |action| action.forward_config&.target_groups&.any? { |tg_conf| target_groups.include?(tg_conf.target_group_arn) } }
      end
    end

    def prepare_deploy_rules(listener_arn, production_tg_arn, exemplar_tg_arn, deploy_tg_arn)
      rules = @client.describe_rules(listener_arn: listener_arn).rules
      production_rules = {}
      exemplar_rules = {}

      # TODO: Support multiple rules per target group.
      rules.each do |rule|
        if rule.actions.any? { |action| action.forward_config&.target_groups&.any? { |tg_conf| tg_conf.target_group_arn == exemplar_tg_arn } }
          exemplar_rules[rule.priority.to_i - PRIORITY_OFFSET] = rule
        elsif rule.actions.any? { |action| action.forward_config && action.forward_config.target_groups.any? { |tg_conf| tg_conf.target_group_arn == production_tg_arn } }
          production_rules[rule.priority.to_i] = rule
        end
      end

      exemplar_rules.map do |(priority, exemplar_rule)|
        production_rule = production_rules[priority]

        if !production_rule
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
    end

    def shift_traffic(rule, amount, production_tg_arn, deploy_tg_arn)
      new_rule = rule.to_h
      forwards = new_rule[:actions].find { |action| action.dig(:forward_config, :target_groups)&.any? { |tg_conf| tg_conf[:target_group_arn] == production_tg_arn } }&.dig(:forward_config, :target_groups)

      if forwards.nil? || forwards.length < 2
        puts "Rule #{new_rule[:rule_arn]} not configured for traffic shift, skipping."
        return
      end

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
      forward = new_rule[:actions].find { |action| action[:type] == 'forward' }

      if forward.nil?
        puts "Rule #{new_rule[:rule_arn]} not configured for traffic shift, skipping."
        return false
      end

      new_config = [{ target_group_arn: production_tg_arn, weight: 100 }]

      forward.delete(:target_group_arn)
      # If we already have a forward config, we only want to update the target groups on it, retaining
      # the target_group_stickiness_config. If we have no forward config then we need to set the
      # full thing.
      if forward.dig(:forward_config, :target_groups)
        forward[:forward_config][:target_groups] = new_config
      else
        forward[:forward_config] = { target_groups: new_config }
      end

      modify_rule(new_rule)
      true
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

    def delete_rule(rule_arn)
      @client.delete_rule(rule_arn: rule_arn)
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
