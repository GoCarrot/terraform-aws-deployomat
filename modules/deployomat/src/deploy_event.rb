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

require 'aws-sdk-ec2'
require 'aws-sdk-eventbridge'
require 'json'
require 'time'

module Deployomat
  # Deployomat's own deploy event, put on the default EventBridge bus of the account it runs
  # in. The detail is a Teak deploy notification (`teak.deploy.notification/1`, the shape
  # notification_log writes), with `ami` as the AMI actually deployed and four more fields:
  #   ami_requested  the AmiId the deploy was started with, when it was a `$` command
  #   ami_tags       every tag on the AMI, {} when there are none or they can't be read
  #   step           the step that put the event (Start, CheckHealthy, Finish, Report...)
  #   status         that step's own Status (undeploying, deploy_active, fail...)
  # `step` and `status` are always present, and null when unset, so every event has the same keys.
  #
  # Reporting never fails a deploy: a lookup or put that goes wrong is one line on stderr.
  # `publish` says whether the event landed, so the caller can leave the run unreported and
  # let the Step Functions status event stand in for it.
  module DeployEvent
    SCHEMA = 'teak.deploy.notification/1'
    SOURCE = 'omat.deployomat'
    DETAIL_TYPE = 'Deployomat Deploy'

    # Reporting runs inline in StartDeploy, whose Lambda has 60s and still has to clone a
    # target group and an ASG. A Lambda timeout is caught by the state machine, not here, and
    # rolls the deploy back, so a stalled EC2 or EventBridge must cost seconds, not tens of
    # them. Worst case: 3s for the lookup (no retry), 6s for the put (one retry).
    EC2_OPTIONS = { retry_limit: 0, http_open_timeout: 1, http_read_timeout: 2 }.freeze
    EVENTS_OPTIONS = { retry_limit: 1, http_open_timeout: 1, http_read_timeout: 2 }.freeze

    def self.ec2_client
      @ec2_client ||= Aws::EC2::Client.new(**EC2_OPTIONS)
    end

    def self.events_client
      @events_client ||= Aws::EventBridge::Client.new(**EVENTS_OPTIONS)
    end

    # Tags on an AMI, as seen with this Lambda's own credentials. Only the AMI's owner sees
    # its tags (an account it's shared with gets none), and deployomat runs in the account
    # that builds the AMIs, so this must not use the workload deploy role.
    def self.ami_tags(ami_id, client: nil)
      return {} unless ami_id.to_s.start_with?('ami-')

      client ||= ec2_client
      image = client.describe_images(image_ids: [ami_id]).images.first
      return warn_empty("#{ami_id} not found") if image.nil?

      (image.tags || []).to_h { |tag| [tag.key, tag.value] }
    rescue StandardError => e
      warn_empty("could not describe #{ami_id}: #{e.class}: #{e.message}")
    end

    # The `ami` and `ami_tags` for a finished event. `resolved` is the Ami Start handed back
    # ({Id, Tags}, symbol or string keys, depending on whether it went through Step Functions).
    # Without one, the requested AmiId stands in when it's an AMI id, and its tags are looked up.
    def self.ami_fields(resolved, requested)
      if resolved
        id = resolved[:Id] || resolved['Id']
        tags = resolved[:Tags] || resolved['Tags']
      else
        id = requested
        tags = ami_tags(requested)
      end
      { ami: id.to_s.start_with?('ami-') ? id : nil, ami_tags: tags || {} }
    end

    # event_id is derived from the execution and phase, so a retried put is one line to a
    # reader that dedupes on it.
    def self.detail(kind:, phase:, service:, account:, execution_arn:, ami: nil, ami_requested: nil, ami_tags: {},
                    errors: [], skip_notifications: false, step: nil, status: nil)
      execution = execution_arn.to_s.split(':').last
      detail = {
        'schema' => SCHEMA,
        'event_id' => "#{execution}/#{phase}",
        'time' => Time.now.utc.iso8601,
        'kind' => kind,
        'phase' => phase,
        'service' => service,
        'account' => account,
        'ami' => ami,
        'execution' => execution,
        'execution_arn' => execution_arn,
        'errors' => Array(errors).map(&:to_s),
        'skip_notifications' => skip_notifications == true,
        'ami_tags' => ami_tags || {},
        'step' => step,
        'status' => status&.to_s
      }
      detail['ami_requested'] = ami_requested if ami_requested && ami_requested != ami
      detail
    end

    # True only when EventBridge accepted the entry. put_events answers 200 with a failed
    # entry count, so a bare success isn't enough.
    def self.publish(detail, client: nil)
      client ||= events_client
      response = client.put_events(
        entries: [{
          source: SOURCE,
          detail_type: DETAIL_TYPE,
          resources: [detail['execution_arn']].compact,
          detail: JSON.generate(detail)
        }]
      )
      return true if response.failed_entry_count.to_i.zero?

      entry = response.data.entries&.first
      warn_false("put_events rejected #{detail['event_id']}: #{entry&.error_code} #{entry&.error_message}")
    rescue StandardError => e
      warn_false("put_events failed for #{detail['event_id']}: #{e.class}: #{e.message}")
    end

    # What a step uses to put its own deploy events. The deploy handler builds one per call from the
    # step's Lambda event and hands it to the step, which calls it where it decides:
    #
    #   return @reporter.failed(Status: :fail, Error: [...])   # puts `failed`, returns the result + Reported
    #   @reporter.emit('healthy')                              # any other event, true when it landed
    #
    # It needs the deploy run's ExecutionArn. A run started on an older definition doesn't pass one,
    # so it puts nothing and every result comes back Reported false.
    class Reporter
      CANCELLED = 'Deploy was cancelled due to a superseding deploy.'

      # `event` is the deploy Lambda's event. Steps after Start get Start's Ami and SkipNotifications
      # from deploy.json; Start has its DeployConfig.
      def self.for_step(event)
        new(
          execution_arn: event['ExecutionArn'], service: event['ServiceName'], account: event['AccountCanonicalSlug'],
          step: event['Step'], ami_requested: event['AmiId'], ami: event['Ami'],
          skip_notifications: event['SkipNotifications'] == true ||
                              event.dig('AllInput', 'DeployConfig', 'SkipNotifications') == true
        )
      end

      # `ami` is the AMI Start resolved, as {Id, Tags}. Without one, `ami_requested` stands in.
      def initialize(execution_arn:, service:, account:, step:, ami_requested: nil, ami: nil, skip_notifications: false)
        @execution_arn = execution_arn
        @service = service
        @account = account
        @step = step
        @ami_requested = ami_requested
        @ami = ami
        @skip_notifications = skip_notifications
      end

      # Puts one deploy event with any phase. True only when it landed; it never raises.
      def emit(phase, status: nil, errors: [], ami: @ami)
        return false unless @execution_arn && @service

        DeployEvent.publish(DeployEvent.detail(
          kind: 'deploy', phase: phase, service: @service, account: @account, execution_arn: @execution_arn,
          ami_requested: @ami_requested, errors: errors, skip_notifications: @skip_notifications,
          step: @step, status: status, **DeployEvent.ami_fields(ami, @ami_requested)
        ))
      rescue StandardError => e
        DeployEvent.warn_false("could not put #{phase} for #{@execution_arn}: #{e.class}: #{e.message}")
      end

      # A result that ends the run: put its finished event, and mark the result Reported, which
      # the state machine's endings read. The errors default to the result's own Error.
      # The result is the step's own, as keywords: `failed(Status: :fail, Error: [...])`.
      def completed(errors: nil, ami: @ami, **result)
        finish('completed', result, errors, ami)
      end

      def failed(errors: nil, ami: @ami, **result)
        finish('failed', result, errors, ami)
      end

      def aborted(errors: nil, ami: @ami, **result)
        finish('aborted', result, errors || (Array(result[:Error]).empty? ? [CANCELLED] : nil), ami)
      end

      private

      def finish(phase, result, errors, ami)
        result.merge(Reported: emit(phase, status: result[:Status], errors: errors || Array(result[:Error]), ami: ami))
      end
    end

    def self.warn_empty(message)
      $stderr.puts("deploy event: #{message}")
      {}
    end

    def self.warn_false(message)
      $stderr.puts("deploy event: #{message}")
      false
    end
  end
end
