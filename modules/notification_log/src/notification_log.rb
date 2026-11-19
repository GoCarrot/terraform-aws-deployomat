# frozen_string_literal: true

# Copyright 2026 Teak.io, Inc.
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

require 'json'
require_relative 'notification_event'

# Lambda handler. Writes one Teak deploy notification per event the module's rule matches to
# stdout, which Lambda sends to this function's log group. The dispatcher reads that log
# group. Uses $stdout.puts, not a Logger, so the log line is the bare JSON.
#
# Two kinds of event arrive. Deployomat's own deploy events already are notifications, and
# are written as they are. Step Functions execution status changes are turned into one,
# unless deployomat already reported that run.
module NotificationLog
  # Which of the three state machines the execution belongs to.
  def self.kind_for(event)
    execution_arn = event.dig('resources', 0)
    sfn_arn = execution_arn.gsub(':execution:', ':stateMachine:').match(/\A(.*):[^:]*\z/)[1]
    case sfn_arn
    when ENV.fetch('DEPLOY_SFN_ARN') then 'deploy'
    when ENV.fetch('UNDEPLOY_SFN_ARN') then 'undeploy'
    when ENV['CANCEL_SFN_ARN'] then 'cancel'
    end
  end

  def self.handler(event:, context:)
    return log_deploy_event(event) if event['source'] == ENV.fetch('DEPLOY_EVENT_SOURCE', 'omat.deployomat')

    kind = kind_for(event)
    if kind.nil?
      puts event
      return "Unknown state machine trigger #{event.dig('resources', 0)}"
    end

    return 'Skipping notification: deployomat reported it.' if NotificationEvent.reported_by_deployomat?(event, kind)

    notification = NotificationEvent.build(event, kind)
    return 'Skipping notification.' if notification.nil?

    log(notification)
  end

  def self.log_deploy_event(event)
    notification = event['detail']
    unless notification.is_a?(Hash) && notification['schema'] == NotificationEvent::SCHEMA
      puts event
      return 'Unknown deploy event'
    end

    log(notification)
  end

  def self.log(notification)
    $stdout.puts(JSON.generate(notification))
    "Logged #{notification['phase']} for #{notification['service']}"
  end
end
