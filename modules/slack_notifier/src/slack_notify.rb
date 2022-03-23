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

require 'json'
require 'net/http'

module SlackNotify
  POST_MESSAGE = URI('https://slack.com/api/chat.postMessage')
  HEADERS = {
    'Content-Type' => 'application/json; charset=utf-8',
    'Authorization' => "Bearer #{ENV['SLACK_BOT_TOKEN']}"
  }

  def self.notification_for_event(event)
    detail = event['detail']
    input = JSON.parse(detail['input'])

    skip_notifications = input.dig('DeployConfig', 'SkipNotifications')

    status = detail['status']
    deployment_desc = "#{input['ServiceName']} to #{input['AccountCanonicalSlug']} (AMI <https://console.aws.amazon.com/ec2/v2/home?region=#{ENV['AWS_REGION']}#ImageDetails:imageId=#{input['AmiId']}|#{input['AmiId']}>, Execution <https://console.aws.amazon.com/states/home?region=#{ENV['AWS_REGION']}#/executions/details/#{detail['executionArn']}|#{detail['name']}>)"
    if status == 'RUNNING'
      return { text: nil } if skip_notifications
      { text: "Started deployment of #{deployment_desc}" }
    elsif status == 'SUCCEEDED'
      output = JSON.parse(detail['output'])
      out_status = output['Status']
      if out_status == 'complete'
        return { text: nil } if skip_notifications
        { text: "Completed deployment of #{deployment_desc}" }
      elsif out_status == 'deploy_aborted'
        { text: "Aborted deployment of #{deployment_desc}" }
      elsif out_status == 'fail'
        { text: "Failed deployment of #{deployment_desc}\n\n#{output['Error'].join("\n")}" }
      else
        { text: "Unknown success result for #{deployment_desc}: #{out_status}" }
      end
    elsif status == 'FAILED'
      { text: "Failed deployment of #{deployment_desc}" }
    else
      { text: "#{status}: deployment of #{deployment_desc} -- LIKELY IN AN INCONSISTENT STATE!!!" }
    end
  end

  def self.notification_for_undeploy(event)
    detail = event['detail']
    input = JSON.parse(detail['input'])

    status = detail['status']
    deployment_desc = "#{input['ServiceName']} from #{input['AccountCanonicalSlug']} (Execution <https://console.aws.amazon.com/states/home?region=#{ENV['AWS_REGION']}#/executions/details/#{detail['executionArn']}|#{detail['name']}>)"
    if status == 'RUNNING'
      { text: "Started undeploy of #{deployment_desc}" }
    elsif status == 'SUCCEEDED'
      output = JSON.parse(detail['output'])
      out_status = output['Status']
      if out_status == 'complete'
        text = "Completed undeployment of #{deployment_desc}"
        if ENV['UNDEPLOY_TECHNO'] == 'true'
          { text: text, blocks: [
            {type: "section", text: { type: "mrkdwn", text: text }},
            {type: "section", text: { type: "mrkdwn", text: "<#{ENV['TECHNO_BEATS']}>"}}
          ]}
        else
          { text: text }
        end
      elsif out_status == 'fail'
        { text: "Failed undeployment of #{deployment_desc}\n\n#{output['Error'].join("\n")}" }
      else
        { text: "Unknown success result for undeployment of #{deployment_desc}: #{out_status}" }
      end
    elsif status == 'FAILED'
      { text: "Failed undeployment of #{deployment_desc}" }
    else
      { text: "#{status}: undeployment of #{deployment_desc} -- LIKELY IN AN INCONSISTENT STATE" }
    end
  end

  def self.notify(request)
    if request[:text].nil? || request[:text].empty?
      return "Skipping notification."
    end

    response = Net::HTTP.start(POST_MESSAGE.host, POST_MESSAGE.port, use_ssl: true) do |http|
      http.post(POST_MESSAGE.path, JSON.generate(request), HEADERS)
    end

    if response.code.to_i != 200
      raise "Error calling slack #{response.body}"
    else
      return "Successfully notified #{ENV['SLACK_CHANNEL']}"
    end
  end

  def self.handler(event:, context:)
    request = {
      channel: ENV['SLACK_CHANNEL'],
    }
    sfn_arn = event.dig('detail', 'stateMachineArn')
    if sfn_arn == ENV['DEPLOY_SFN_ARN']
      request.merge!(notification_for_event(event))
    elsif sfn_arn == ENV['UNDEPLOY_SFN_ARN']
      request.merge!(notification_for_undeploy(event))
    else
      puts event
      return "Unknown state function trigger #{sfn_arn}"
    end

    notify(request)
  end
end
