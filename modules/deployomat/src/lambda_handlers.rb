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
require_relative 'cancel'
require_relative 'deploy'
require_relative 'undeploy'

require 'json'

module LambdaFunctions
  class Handler
    def self.cancel(event:, context:)
      args = {
        account_canonical_slug: event['AccountCanonicalSlug'], service_name: event['ServiceName'],
        deploy_id: "cancel-#{event['DeployId']}"
      }
      config = Deployomat::Config.new(args)
      op =
        if event['Step'] == 'Start'
          Deployomat::StartCancel.new(config)
        else
          Deployomat::FinishCancel.new(config)
        end
      op.call
    end

    def self.deploy(event:, context:)
      args = {
        account_canonical_slug: event['AccountCanonicalSlug'], service_name: event['ServiceName'],
        deploy_id: "deploy-#{event['DeployId']}"
      }
      config = Deployomat::Config.new(args)
      op =
        case event['Step']
        when 'Start'
          Deployomat::StartDeploy.new(config, ami_id: event['AmiId'], deploy_config: event.dig('AllInput', 'DeployConfig'))
        when 'CheckHealthy'
          Deployomat::CheckHealthy.new(
            config, max_wait: event['WaitTime'], min_healthy: event['MinHealthy'],
            remaining_time: event.dig('StepResult', 'RemainingTime'),
            target_group_arn: event['TargetGroupArn']
          )
        when 'Rollout'
          Deployomat::Rollout.new(
            config, step_size: event['StepSize'], step_delay: event['StepDelay'],
            rule_ids: event['RuleIds'], target_group_arn: event['TargetGroupArn'],
            old_target_group_arn: event['OldTargetGroupArn'], progress: event.dig('StepResult', 'Progress')
          )
        when 'Coalesce'
          Deployomat::Coalesce.new(
            config, target_group_arn: event['TargetGroupArn'], rule_ids: event['RuleIds']
          )
        when 'Bake'
          Deployomat::Bake.new(
            config, target_group_arn: event['TargetGroupArn'], rule_ids: event['RuleIds'],
            bake_time: event['BakeTime'], remaining_time: event.dig('StepResult', 'RemainingTime')
          )
        when 'Finish'
          Deployomat::FinishDeploy.new(
            config, allow_undeploy: event['AllowUndeploy'], automatic_undeploy_minutes: event['AutomaticUndeployMinutes']
          )
        else
          return { Status: :fail, Error: ["Unexpected step: '#{event['Step']}'"] }
        end
      op.call
    end

    def self.undeploy(event:, context:)
      args = {
        account_canonical_slug: event['AccountCanonicalSlug'], service_name: event['ServiceName'],
        deploy_id: "undeploy-#{event['DeployId']}"
      }
      config = Deployomat::Config.new(args)
      op = Deployomat::Undeploy.new(config, undeploy_config: event.dig('AllInput', 'UndeployConfig'))
      op.call
    end
  end
end
