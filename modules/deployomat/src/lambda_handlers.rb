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
      if event['Step'] == 'Report'
        return report_failure('cancel', event, cancel_failure(event['AllInput']))
      end

      args = {
        account_canonical_slug: event['AccountCanonicalSlug'], service_name: event['ServiceName'],
        deploy_id: "cancel-#{event['DeployId']}"
      }
      config = Deployomat::Config.new(**args)
      reporter = Deployomat::DeployEvent::Reporter.for_run(event, 'cancel')
      op =
        if event['Step'] == 'Start'
          Deployomat::StartCancel.new(config, reporter: reporter)
        else
          Deployomat::FinishCancel.new(config, reporter: reporter)
        end
      reported(op.call)
    end

    def self.deploy(event:, context:)
      if event['Step'] == 'Report'
        return Deployomat::ReportDeploy.new(all_input: event['AllInput'], execution_arn: event['ExecutionArn']).call
      end

      args = {
        account_canonical_slug: event['AccountCanonicalSlug'], service_name: event['ServiceName'],
        deploy_id: "deploy-#{event['DeployId']}"
      }
      config = Deployomat::Config.new(**args)
      # Each step puts its own deploy events through this, where it decides how the run went.
      reporter = Deployomat::DeployEvent::Reporter.for_step(event)
      op =
        case event['Step']
        when 'Start'
          Deployomat::StartDeploy.new(
            config, ami_id: event['AmiId'], deploy_config: event.dig('AllInput', 'DeployConfig'), reporter: reporter
          )
        when 'CheckHealthy'
          Deployomat::CheckHealthy.new(
            config, max_wait: event['WaitTime'], min_healthy: event['MinHealthy'],
            remaining_time: event.dig('StepResult', 'RemainingTime'),
            target_group_arn: event['TargetGroupArn'], reporter: reporter
          )
        when 'Rollout'
          Deployomat::Rollout.new(
            config, step_size: event['StepSize'], step_delay: event['StepDelay'],
            rule_ids: event['RuleIds'], target_group_arn: event['TargetGroupArn'],
            old_target_group_arn: event['OldTargetGroupArn'], progress: event.dig('StepResult', 'Progress'),
            reporter: reporter
          )
        when 'Coalesce'
          Deployomat::Coalesce.new(
            config, target_group_arn: event['TargetGroupArn'], rule_ids: event['RuleIds'], reporter: reporter
          )
        when 'Bake'
          Deployomat::Bake.new(
            config, target_group_arn: event['TargetGroupArn'], rule_ids: event['RuleIds'],
            bake_time: event['BakeTime'], remaining_time: event.dig('StepResult', 'RemainingTime'),
            reporter: reporter
          )
        when 'Finish'
          Deployomat::FinishDeploy.new(
            config, allow_undeploy: event['AllowUndeploy'], automatic_undeploy_minutes: event['AutomaticUndeployMinutes'],
            reporter: reporter
          )
        else
          return { Status: :fail, Error: ["Unexpected step: '#{event['Step']}'"] }
        end
      result = op.call
      # deploy.json's endings read Reported. A result that ends the run without a step reporting it
      # ends unmarked, and the Step Functions status-event readers report it instead.
      result.key?(:Reported) ? result : result.merge(Reported: false)
    end

    def self.undeploy(event:, context:)
      if event['Step'] == 'Report'
        status = event.dig('AllInput', 'StartResult', 'Status')
        return report_failure('undeploy', event, "Unexpected result from Start: #{status.inspect}")
      end

      args = {
        account_canonical_slug: event['AccountCanonicalSlug'], service_name: event['ServiceName'],
        deploy_id: "undeploy-#{event['DeployId']}"
      }
      config = Deployomat::Config.new(**args)
      reporter = Deployomat::DeployEvent::Reporter.for_run(event, 'undeploy')
      op = Deployomat::Undeploy.new(config, undeploy_config: event.dig('AllInput', 'UndeployConfig'), reporter: reporter)
      reported(op.call)
    end

    # The state machines' endings read Reported. A result that ends the run without a step reporting
    # it ends unmarked, and the Step Functions status-event readers report it instead. Cancel's Start
    # answers with a bare status, which nothing reads Reported from.
    def self.reported(result)
      return result unless result.is_a?(Hash)

      result.key?(:Reported) ? result : result.merge(Reported: false)
    end

    def self.report_failure(kind, event, error)
      Deployomat::DeployEvent::ReportFailure.call(
        kind: kind, all_input: event['AllInput'], execution_arn: event['ExecutionArn'], error: error
      )
    end

    # Why cancel.json reached its Report step: Start found no deploy to cancel, or answered something unexpected.
    def self.cancel_failure(all_input)
      input = all_input.is_a?(Hash) ? all_input : {}
      start = input['StartResult']
      return "No deployment of #{input['ServiceName']} in #{input['AccountCanonicalSlug']} active" if start == 'fail'

      "Unexpected result from Start: #{start.inspect}"
    end
  end
end
