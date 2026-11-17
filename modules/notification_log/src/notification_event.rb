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
require 'time'

# Turns a Step Functions execution status change event into a Teak deploy notification: a
# flat Hash that says what happened to which service, with nothing in it that is specific
# to Step Functions. This is the only place that knows Step Functions' statuses, its
# JSON-in-a-string input and output, or that a SUCCEEDED run can mean a failed deploy.
# Anything downstream reads the notification, so moving off Step Functions means
# rewriting this file.
#
# Schema `teak.deploy.notification/1`:
#   schema, event_id, time (iso8601), kind (deploy|cancel|undeploy),
#   phase (started|completed|failed|aborted|unknown), service, account, ami (or nil),
#   execution, execution_arn, errors (array of strings), skip_notifications (bool)
module NotificationEvent
  SCHEMA = 'teak.deploy.notification/1'

  # Present in the input of an execution that another execution started: the cancels that
  # a deploy or undeploy kicks off for a concurrent deploy or a rollback.
  PARENT_KEY = 'AWS_STEP_FUNCTIONS_STARTED_BY_EXECUTION_ID'

  # The error of a deploy run that failed after deployomat reported it (deploy.json FailReported).
  REPORTED_ERROR = 'Deployomat.Reported'

  OUTPUT_PHASES = {
    'complete' => 'completed',
    'deploy_aborted' => 'aborted',
    'fail' => 'failed'
  }.freeze

  # Returns the notification Hash, or nil for an event that should not notify: a nested
  # cancel (its parent reports, so one failed deploy is one finish line) or a status this
  # rule never matches.
  def self.build(event, kind)
    detail = event.fetch('detail')
    input = parse(detail['input'])
    return nil if input.key?(PARENT_KEY)

    phase, errors = phase_and_errors(detail)
    return nil if phase.nil?

    {
      'schema' => SCHEMA,
      'event_id' => event['id'],
      'time' => event['time'] || Time.now.utc.iso8601,
      'kind' => kind,
      'phase' => phase,
      'service' => input['ServiceName'] || 'unknown',
      'account' => input['AccountCanonicalSlug'] || 'unknown',
      'ami' => input['AmiId'],
      'execution' => detail['name'],
      'execution_arn' => detail['executionArn'],
      'errors' => errors,
      'skip_notifications' => input.dig('DeployConfig', 'SkipNotifications') == true
    }
  end

  # Deployomat puts its own events for a deploy: started once it knows the AMI, and the
  # ending from its Report step, which marks a run whose event landed. A deploy's status event
  # is then only a backstop, for what deployomat didn't report: a timeout, a console stop, a
  # crash, or an event that didn't land. True when the status event is already covered.
  def self.reported_by_deployomat?(event, kind)
    return false unless kind == 'deploy'

    detail = event.fetch('detail')
    case detail['status']
    when 'RUNNING' then true
    when 'SUCCEEDED' then parse(detail['output'])['Reported'] == true
    when 'FAILED' then detail['error'] == REPORTED_ERROR
    else false
    end
  end

  def self.phase_and_errors(detail)
    case detail['status']
    when 'RUNNING'
      ['started', []]
    when 'SUCCEEDED'
      output = parse(detail['output'])
      phase = OUTPUT_PHASES[output['Status']]
      return [phase, Array(output['Error']).map(&:to_s)] if phase

      ['unknown', ["Unknown success result: #{output['Status'].inspect}"]]
    when 'FAILED'
      ['failed', [detail['error'], detail['cause']].compact.map(&:to_s)]
    when 'UPDATE'
      [nil, []]
    else
      ['unknown', ["Execution #{detail['status']}; likely in an inconsistent state"]]
    end
  end

  # input and output arrive as JSON strings, and may be missing or not an object.
  def self.parse(json)
    parsed = JSON.parse(json.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
